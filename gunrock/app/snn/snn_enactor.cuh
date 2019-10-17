// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * snn_enactor.cuh
 *
 * @brief snn Problem Enactor
 */

#pragma once

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/enactor_iteration.cuh>
#include <gunrock/app/enactor_loop.cuh>
#include <gunrock/oprtr/oprtr.cuh>

#include <gunrock/app/snn/snn_problem.cuh>
#include <gunrock/util/scan_device.cuh>
#include <gunrock/util/sort_device.cuh>

#include <gunrock/oprtr/1D_oprtr/for.cuh>
#include <gunrock/oprtr/oprtr.cuh>

//KNN app
#include <gunrock/app/knn/knn_enactor.cuh>
#include <gunrock/app/knn/knn_test.cuh>

//#define SNN_DEBUG 1

#define debug2(a...)
//#define debug2(a...) printf(a)

#ifdef SNN_DEBUG
#define debug(a...) printf(a)
#else
#define debug(a...)
#endif

namespace gunrock {
namespace app {
namespace snn {

/**
 * @brief Speciflying parameters for snn Enactor
 * @param parameters The util::Parameter<...> structure holding all parameter
 * info \return cudaError_t error message(s), if any
 */
cudaError_t UseParameters_enactor(util::Parameters &parameters) {
  cudaError_t retval = cudaSuccess;
  GUARD_CU(app::UseParameters_enactor(parameters));

  return retval;
}

/**
 * @brief defination of snn iteration loop
 * @tparam EnactorT Type of enactor
 */
template <typename EnactorT>
struct snnIterationLoop : public IterationLoopBase<EnactorT, Use_FullQ | Push> {
  typedef typename EnactorT::VertexT VertexT;
  typedef typename EnactorT::SizeT SizeT;
  typedef typename EnactorT::ValueT ValueT;
  typedef typename EnactorT::Problem::GraphT::CsrT CsrT;
  typedef typename EnactorT::Problem::GraphT::GpT GpT;

  typedef IterationLoopBase<EnactorT, Use_FullQ | Push> BaseIterationLoop;

  snnIterationLoop() : BaseIterationLoop() {}

  /**
   * @brief Core computation of knn, one iteration
   * @param[in] peer_ Which GPU peers to work on, 0 means local
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Core(int peer_ = 0) {
    // --
    // Alias variables

    auto &data_slice = this->enactor->problem->data_slices[this->gpu_num][0];

    auto &enactor_slice =
        this->enactor
            ->enactor_slices[this->gpu_num * this->enactor->num_gpus + peer_];

    auto &enactor_stats = enactor_slice.enactor_stats;
    auto &graph = data_slice.sub_graph[0];
    auto nodes = graph.nodes;
    auto edges = graph.edges;
    auto &frontier = enactor_slice.frontier;
    auto &oprtr_parameters = enactor_slice.oprtr_parameters;
    auto &retval = enactor_stats.retval;
    auto &iteration = enactor_stats.iteration;

    // struct Point()
    //auto &distances = data_slice.distances;

    // K-Nearest Neighbors data
    auto &knn_enactor = this->enactor->knn_enactor;
    auto &knn_problem = this->enactor->problem->knn_problem;
    auto &knn_problem_data = knn_problem.data_slices[this->gpu_num][0];
    auto &knns = knn_problem_data.knns;
    auto &keys = knn_problem_data.keys;
    auto &keys_out = knn_problem_data.keys_out;

    // Shared Nearest Neighbors
    //auto &knns = data_slice.knns;
    auto &core_point_mark_0 = data_slice.core_point_mark_0;
    auto &core_point_mark = data_slice.core_point_mark;
    auto &core_points = data_slice.core_points;
    auto &core_points_counter = data_slice.core_points_counter;
    auto &cluster_id = data_slice.cluster_id;
    auto &snn_density = data_slice.snn_density;

    // Number of KNNs
    auto k = data_slice.k;
    auto eps = data_slice.eps;
    auto min_pts = data_slice.min_pts;

    // Reference Point
    auto ref_src = data_slice.point_x;
    auto ref_dest = data_slice.point_y;

    // CUB Related storage
    auto &cub_temp_storage = data_slice.cub_temp_storage;

    // Sorted arrays
    auto &distances_out = data_slice.distances;
    //auto &keys_out = knn_problem_data.keys_out;

    cudaStream_t stream = oprtr_parameters.stream;
    auto target = util::DEVICE;
    util::Array1D<SizeT, VertexT> *null_frontier = NULL;

    // Perform SNN
    auto &snn = data_slice.snn;

    oprtr_parameters.advance_mode = "ALL_EDGES";

    // Perform KNN
    knn_problem.parameters.Set("k", k);
    GUARD_CU(knn_problem.Reset(ref_src, ref_dest, k, target));
    GUARD_CU(cudaDeviceSynchronize());
    GUARD_CU(knn_enactor.Enact());
    GUARD_CU(cudaDeviceSynchronize());

    if (snn) {
      // SNN density of each point
      auto density_op =
          [graph, nodes, knns, k, eps, snn_density, min_pts] __host__
          __device__(VertexT * v_q, const SizeT &pos) {
            auto src = pos / k;
            auto i = pos % k;
            auto src_neighbors = graph.CsrT::GetNeighborListLength(src);
            auto src_start = graph.CsrT::GetNeighborListOffset(src);
            auto src_end = src_start + src_neighbors;
            if (src_neighbors < k) return;

            // chose i nearest neighbor
            auto neighbor = knns[src * k + i];

            // go over neighbors of the nearest neighbor
            auto knn_start = graph.CsrT::GetNeighborListOffset(neighbor);
            auto knn_neighbors = graph.CsrT::GetNeighborListLength(neighbor);
            auto knn_end = knn_start + knn_neighbors;
            int num_shared_neighbors = 0;

            // Loop over k's neighbors
            for (auto j = knn_start; j < knn_end; ++j) {
              // Get the neighbor of active k from the edge:
              auto m = graph.CsrT::GetEdgeDest(j);
              for (auto v = src_start; v < src_end; ++v) {
                auto possible_src = graph.CsrT::GetEdgeDest(v);
                if (m == possible_src) ++num_shared_neighbors;
              }
            }

            // if src and neighbor share eps or more neighbors then increase
            // snn density
            if (num_shared_neighbors >= eps) {
              atomicAdd(&snn_density[src], 1);
            }
          };

      // Find density of each point
      GUARD_CU(
          frontier.V_Q()->ForAll(density_op, nodes * k, target, stream));

      // Find core points
      GUARD_CU(core_point_mark_0.ForAll(
          [graph, snn_density, min_pts] __host__ __device__(SizeT * cp,
                                                            const SizeT &pos) {
            if (snn_density[pos] >= min_pts) {
              cp[pos] = 1;
            }
          },
          nodes, target, stream));

      GUARD_CU(util::cubInclusiveSum(cub_temp_storage, core_point_mark_0,
                                     core_point_mark, nodes, stream));

      GUARD_CU(core_points.ForAll(
          [nodes, core_point_mark, core_points_counter] __host__ __device__(
              SizeT * cps, const SizeT &pos) {
            if ((pos == 0 && core_point_mark[pos] != 0) ||
                (pos > 0 && core_point_mark[pos] != core_point_mark[pos - 1])) {
              cps[core_point_mark[pos] - 1] = pos;
            }
            if (pos == nodes - 1) core_points_counter[0] = core_point_mark[pos];
          },
          nodes, target, stream));

      // Core points merging
      auto merging_op =
          [graph, nodes, eps, core_point_mark, core_points, core_points_counter,
           cluster_id] __host__
          __device__(const int &counter, const VertexT &p) {
            auto cp_counter = core_points_counter[0];
            auto x = core_points[p / cp_counter];
            auto y = core_points[p % cp_counter];
            if (x >= nodes || y >= nodes) {
              debug2("sth wrong x=%d, y=%d, cp_counter = %d\n", x, y,
                     cp_counter);
              return;
            }
            if ((x == 0 && core_point_mark[x] != 1) ||
                (x > 0 && core_point_mark[x] == core_point_mark[x - 1])) {
              debug2("x %d, if you see this, algo is really wrong..\n", x);
              return;
            }
            if ((y == 0 && core_point_mark[y] != 1) ||
                (y > 0 && core_point_mark[y] == core_point_mark[y - 1])) {
              debug2("y %d if you see this, algo is really wrong..\n", y);
              return;
            }
            // go over neighbors of core point x
            auto x_start = graph.CsrT::GetNeighborListOffset(x);
            auto x_neighbors = graph.CsrT::GetNeighborListLength(x);
            auto x_end = x_start + x_neighbors;
            // go over neighbors of core point src
            auto y_start = graph.CsrT::GetNeighborListOffset(y);
            auto y_neighbors = graph.CsrT::GetNeighborListLength(y);
            auto y_end = y_start + y_neighbors;
            int num_shared_neighbors = 0;
            for (auto xn = x_start; xn < x_end; ++xn) {
              auto m = graph.CsrT::GetEdgeDest(xn);
              for (auto yn = y_start; yn < y_end; ++yn) {
                auto k = graph.CsrT::GetEdgeDest(yn);
                if (m == k) ++num_shared_neighbors;
                if (num_shared_neighbors >= eps) break;
              }
              if (num_shared_neighbors >= eps) break;
            }
            // if src and neighbor share eps or more neighbors then merge
            if (num_shared_neighbors >= eps) {
              auto cluster_id_x = cluster_id[x];
              auto cluster_id_y = cluster_id[y];
              auto cluster_min = min(cluster_id_x, cluster_id_y);
              atomicMin(cluster_id + x, cluster_min);
              atomicMin(cluster_id + y, cluster_min);
            }
          };

      GUARD_CU(
          core_points_counter.Move(util::DEVICE, util::HOST, 1, 0, stream));
      GUARD_CU2(cudaStreamSynchronize(stream), "cudaStreamSynchronize failed");
      printf("Core points found: %d\n", core_points_counter[0]);

      // Assign core points to clusters
      SizeT loop_size = core_points_counter[0] * core_points_counter[0];
      SizeT num_repeats = log2(core_points_counter[0]);
      gunrock::oprtr::RepeatFor(
          merging_op, num_repeats, loop_size, util::DEVICE, stream,
          util::PreDefinedValues<int>::InvalidValue,  // grid_size
          util::PreDefinedValues<int>::InvalidValue,  // block_size
          2);

      // Assign other non-core and non-noise points to clusters
      auto clustering_op =
          [graph, core_point_mark, keys, keys_out, k, cluster_id,
           min_pts] __host__
          __device__(VertexT * v_q, const SizeT &src) {
            // only non-core points
            if (src == 0 && core_point_mark[src] == 1) return;
            if (src > 0 && core_point_mark[src - 1] != core_point_mark[src])
              return;

            if (src == 0)
                printf("src = %d, 0 clustering op \n", src); 


            // only non-noise points
            auto num_neighbors = graph.CsrT::GetNeighborListLength(src);
            if (num_neighbors < k) return;  // (was k)
            auto e_start = graph.CsrT::GetNeighborListOffset(src);
            for (auto e = e_start; e < e_start + num_neighbors; ++e) {
              auto m = graph.CsrT::GetEdgeDest(keys_out[keys[e]]);
              if ((m == 0 && core_point_mark[m] == 1) ||
                  (m > 0 && core_point_mark[m] != core_point_mark[m - 1])) {
                cluster_id[src] = cluster_id[m];
                break;
              }
            }

            if (src == 0)
                printf("src = %d, 1 clustering op\n", src);
          };

      // Assign other non-core and non-noise points to clusters
      GUARD_CU(frontier.V_Q()->ForAll(clustering_op, nodes, target, stream));
    }

    GUARD_CU(frontier.work_progress.GetQueueLength(
        frontier.queue_index, frontier.queue_length, false, stream, true));

    return retval;
  }

  /**
   * @brief Routine to combine received data and local data
   * @tparam NUM_VERTEX_ASSOCIATES Number of data associated with each
   * transmition item, typed VertexT
   * @tparam NUM_VALUE__ASSOCIATES Number of data associated with each
   * transmition item, typed ValueT
   * @param  received_length The numver of transmition items received
   * @param[in] peer_ which peer GPU the data came from
   * \return cudaError_t error message(s), if any
   */
  template <int NUM_VERTEX_ASSOCIATES, int NUM_VALUE__ASSOCIATES>
  cudaError_t ExpandIncoming(SizeT &received_length, int peer_) {
    // ================ INCOMPLETE TEMPLATE - MULTIGPU ====================

    auto &data_slice = this->enactor->problem->data_slices[this->gpu_num][0];
    auto &enactor_slice =
        this->enactor
            ->enactor_slices[this->gpu_num * this->enactor->num_gpus + peer_];
    // auto iteration = enactor_slice.enactor_stats.iteration;
    // TODO: add problem specific data alias here, e.g.:
    // auto         &distances          =   data_slice.distances;

    auto expand_op = [
                         // TODO: pass data used by the lambda, e.g.:
                         // distances
    ] __host__ __device__(VertexT & key, const SizeT &in_pos,
                          VertexT *vertex_associate_ins,
                          ValueT *value__associate_ins) -> bool {
      // TODO: fill in the lambda to combine received and local data, e.g.:
      // ValueT in_val  = value__associate_ins[in_pos];
      // ValueT old_val = atomicMin(distances + key, in_val);
      // if (old_val <= in_val)
      //     return false;
      return true;
    };

    cudaError_t retval =
        BaseIterationLoop::template ExpandIncomingBase<NUM_VERTEX_ASSOCIATES,
                                                       NUM_VALUE__ASSOCIATES>(
            received_length, peer_, expand_op);
    return retval;
  }

  bool Stop_Condition(int gpu_num = 0) {
    auto it = this->enactor->enactor_slices[0].enactor_stats.iteration;
    if (it > 0)
      return true;
    else
      return false;
  }
};  // end of snnIteration

/**
 * @brief snn enactor class.
 * @tparam _Problem Problem type we process on
 * @tparam ARRAY_FLAG Flags for util::Array1D used in the enactor
 * @tparam cudaHostRegisterFlag Flags for util::Array1D used in the enactor
 */
template <typename _Problem, util::ArrayFlag ARRAY_FLAG = util::ARRAY_NONE,
          unsigned int cudaHostRegisterFlag = cudaHostRegisterDefault>
class Enactor
    : public EnactorBase<
          typename _Problem::GraphT, typename _Problem::GraphT::VertexT,
          typename _Problem::GraphT::ValueT, ARRAY_FLAG, cudaHostRegisterFlag> {
 public:
  typedef _Problem Problem;
  typedef typename Problem::SizeT SizeT;
  typedef typename Problem::VertexT VertexT;
  typedef typename Problem::GraphT GraphT;
  typedef typename Problem::KnnProblemT KnnProblemT;
  typedef typename GraphT::VertexT LabelT;
  typedef typename GraphT::ValueT ValueT;
  typedef EnactorBase<GraphT, LabelT, ValueT, ARRAY_FLAG, cudaHostRegisterFlag>
      BaseEnactor;
  typedef Enactor<Problem, ARRAY_FLAG, cudaHostRegisterFlag> EnactorT;
  typedef snnIterationLoop<EnactorT> IterationT;

  Problem *problem;
  IterationT *iterations;
  typedef knn::Enactor<KnnProblemT> KnnEnactorT;
  KnnEnactorT knn_enactor;

  /**
   * @brief snn constructor
   */
  Enactor() : BaseEnactor("SNN"), knn_enactor(), problem(NULL) {
    this->max_num_vertex_associates = 0;
    this->max_num_value__associates = 1;
  }

  /**
   * @brief snn destructor
   */
  virtual ~Enactor() { /*Release();*/
  }

  /*
   * @brief Releasing allocated memory space
   * @param target The location to release memory from
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Release(util::Location target = util::LOCATION_ALL) {
    cudaError_t retval = cudaSuccess;
    GUARD_CU(BaseEnactor::Release(target));
    delete[] iterations;
    iterations = NULL;
    problem = NULL;
    return retval;
  }

  /**
   * @brief Initialize the problem.
   * @param[in] problem The problem object.
   * @param[in] target Target location of data
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Init(Problem &problem, util::Location target = util::DEVICE) {
    cudaError_t retval = cudaSuccess;
    this->problem = &problem;

    // Lazy initialization
    GUARD_CU(BaseEnactor::Init(problem, Enactor_None, 2, NULL, target, false));
    GUARD_CU(knn_enactor.Init(problem.knn_problem, target));

    for (int gpu = 0; gpu < this->num_gpus; gpu++) {
      GUARD_CU(util::SetDevice(this->gpu_idx[gpu]));
      auto &enactor_slice = this->enactor_slices[gpu * this->num_gpus + 0];
      auto &graph = problem.sub_graphs[gpu];
      GUARD_CU(enactor_slice.frontier.Allocate(graph.nodes, graph.edges,
                                               this->queue_factors));
    }

    iterations = new IterationT[this->num_gpus];
    for (int gpu = 0; gpu < this->num_gpus; gpu++) {
      GUARD_CU(iterations[gpu].Init(this, gpu));
    }

    GUARD_CU(this->Init_Threads(
        this, (CUT_THREADROUTINE) & (GunrockThread<EnactorT>)));
    return retval;
  }

  /**
   * @brief one run of snn, to be called within GunrockThread
   * @param thread_data Data for the CPU thread
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Run(ThreadSlice &thread_data) {
    gunrock::app::Iteration_Loop<
        // change to how many {VertexT, ValueT} data need to communicate
        //       per element in the inter-GPU sub-frontiers
        0, 1, IterationT>(thread_data, iterations[thread_data.thread_num]);
    return cudaSuccess;
  }

  /**
   * @brief Reset enactor
...
   * @param[in] target Target location of data
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Reset(util::Location target = util::DEVICE) {
    typedef typename GraphT::GpT GpT;
    cudaError_t retval = cudaSuccess;

    GUARD_CU(BaseEnactor::Reset(target));
    GUARD_CU(knn_enactor.Reset(target));

    SizeT nodes = this->problem->data_slices[0][0].sub_graph[0].nodes;

    for (int gpu = 0; gpu < this->num_gpus; gpu++) {
      if (this->num_gpus == 1) {
        this->thread_slices[gpu].init_size = nodes;
        for (int peer_ = 0; peer_ < this->num_gpus; peer_++) {
          auto &frontier =
              this->enactor_slices[gpu * this->num_gpus + peer_].frontier;
          frontier.queue_length = (peer_ == 0) ? nodes : 0;
          if (peer_ == 0) {
            util::Array1D<SizeT, VertexT> tmp;
            tmp.Allocate(nodes, target | util::HOST);
            for (SizeT i = 0; i < nodes; ++i) {
              tmp[i] = (VertexT)i % nodes;
            }
            GUARD_CU(tmp.Move(util::HOST, target));

            GUARD_CU(frontier.V_Q()->ForEach(
                tmp,
                [] __host__ __device__(VertexT & v, VertexT & i) { v = i; },
                nodes, target, 0));

            tmp.Release();
          }
        }
      } else {
        // MULTIGPU INCOMPLETE
      }
    }

    GUARD_CU(BaseEnactor::Sync());
    return retval;
  }

  /**
   * @brief Enacts a snn computing on the specified graph.
...
   * \return cudaError_t error message(s), if any
   */
  cudaError_t Enact() {
    cudaError_t retval = cudaSuccess;
    GUARD_CU(this->Run_Threads(this));
    util::PrintMsg("GPU SNN Done.", this->flag & Debug);
    return retval;
  }
};

}  // namespace knn
}  // namespace app
}  // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
