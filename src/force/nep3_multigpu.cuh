/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/

#pragma once
#include "potential.cuh"
#include "utilities/gpu_vector.cuh"

struct NEP3_MULTIGPU_Data {
  GPU_Vector<float> f12x; // 3-body or manybody partial forces
  GPU_Vector<float> f12y; // 3-body or manybody partial forces
  GPU_Vector<float> f12z; // 3-body or manybody partial forces
  GPU_Vector<float> Fp;
  GPU_Vector<float> sum_fxyz;
  GPU_Vector<int> NN_radial;    // radial neighbor list
  GPU_Vector<int> NL_radial;    // radial neighbor list
  GPU_Vector<int> NN_angular;   // angular neighbor list
  GPU_Vector<int> NL_angular;   // angular neighbor list
  GPU_Vector<float> parameters; // parameters to be optimized
  GPU_Vector<int> cell_count;
  GPU_Vector<int> cell_count_sum;
  GPU_Vector<int> cell_contents;

  GPU_Vector<int> type;
  GPU_Vector<double> position;
  GPU_Vector<double> force;
  GPU_Vector<double> potential;
  GPU_Vector<double> virial;

  int N1, N2, N3; // ending indices in local system
  int M0, M1, M2; // starting indices in global system
  cudaStream_t stream;
};

struct NEP3_TEMP_Data {
  int num_atoms_per_gpu;
  std::vector<int> cell_count_sum_cpu;
  GPU_Vector<int> cell_count;
  GPU_Vector<int> cell_count_sum;
  GPU_Vector<int> cell_contents;
  GPU_Vector<int> type;
  GPU_Vector<double> position;
  GPU_Vector<double> force;
  GPU_Vector<double> potential;
  GPU_Vector<double> virial;
};

class NEP3_MULTIGPU : public Potential
{
public:
  struct ParaMB {
    int num_gpus = 1;
    int version = 2;            // NEP version, 2 for NEP2 and 3 for NEP3
    float rc_radial = 0.0f;     // radial cutoff
    float rc_angular = 0.0f;    // angular cutoff
    float rcinv_radial = 0.0f;  // inverse of the radial cutoff
    float rcinv_angular = 0.0f; // inverse of the angular cutoff
    int MN_radial = 200;
    int MN_angular = 100;
    int n_max_radial = 0;  // n_radial = 0, 1, 2, ..., n_max_radial
    int n_max_angular = 0; // n_angular = 0, 1, 2, ..., n_max_angular
    int L_max = 0;         // l = 0, 1, 2, ..., L_max
    int dim_angular;
    int num_L;
    int basis_size_radial = 8;  // for nep3
    int basis_size_angular = 8; // for nep3
    int num_types_sq = 0;       // for nep3
    int num_c_radial = 0;       // for nep3
    int num_types = 0;
    float q_scaler[140];
  };

  struct ANN {
    int dim = 0;          // dimension of the descriptor
    int num_neurons1 = 0; // number of neurons in the 1st hidden layer
    int num_para = 0;     // number of parameters
    const float* w0;      // weight from the input layer to the hidden layer
    const float* b0;      // bias for the hidden layer
    const float* w1;      // weight from the hidden layer to the output layer
    const float* b1;      // bias for the output layer
    const float* c;
  };

  struct ZBL {
    bool enabled = false;
    float rc_inner = 1.0f;
    float rc_outer = 2.0f;
    float atomic_numbers[10];
  };

  NEP3_MULTIGPU(const int num_gpus, char* file_potential, const int num_atoms);
  virtual ~NEP3_MULTIGPU(void);
  virtual void compute(
    const int group_method,
    std::vector<Group>& group,
    const int type_begin,
    const int type_end,
    const int type_shift,
    Box& box,
    const GPU_Vector<int>& type,
    const GPU_Vector<double>& position,
    GPU_Vector<double>& potential,
    GPU_Vector<double>& force,
    GPU_Vector<double>& virial);

private:
  ParaMB paramb;
  ANN annmb[16];
  ZBL zbl;
  NEP3_MULTIGPU_Data nep_data[16];
  NEP3_TEMP_Data nep_temp_data;

  void update_potential(const float* parameters, ANN& ann);
};