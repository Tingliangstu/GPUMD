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

/*----------------------------------------------------------------------------80
References for implementation:
[1] Ceriotti et al., J. Chem. Phys. 133, 124104 (2010).
[2] Mariana Rossi et al., J. Chem. Phys. 140, 234116 (2014).
------------------------------------------------------------------------------*/

#include "ensemble_pimd.cuh"
#include "langevin_utilities.cuh"
#include "utilities/common.cuh"
#include <cstdlib>

Ensemble_PIMD::Ensemble_PIMD(
  int number_of_atoms_input,
  int number_of_beads_input,
  double temperature_input,
  double temperature_coupling_input,
  double temperature_coupling_beads_input)
{
  number_of_atoms = number_of_atoms_input;
  number_of_beads = number_of_beads_input;
  temperature = temperature_input;
  temperature_coupling = temperature_coupling_input;
  omega_n = number_of_beads * K_B * temperature / HBAR;

  position.resize(number_of_beads);
  velocity.resize(number_of_beads);
  force.resize(number_of_beads);
  for (int b = 0; b < number_of_beads; ++b) {
    position[b].resize(number_of_atoms * 3);
    velocity[b].resize(number_of_atoms * 3);
    force[b].resize(number_of_atoms * 3);
    beads.position[b] = position[b].data();
    beads.velocity[b] = velocity[b].data();
    beads.force[b] = force[b].data();
  }

  // TODO: initializing position and velocity data for the beads

  transformation_matrix.resize(number_of_beads * number_of_beads);
  std::vector<double> transformation_matrix_cpu(number_of_beads * number_of_beads);
  double sqrt_factor_1 = sqrt(1.0 / number_of_beads);
  double sqrt_factor_2 = sqrt(2.0 / number_of_beads);
  for (int j = 1; j <= number_of_beads; ++j) {
    float sign_factor = (j % 2 == 0) ? 1.0f : -1.0f;
    for (int k = 0; k < number_of_beads; ++k) {
      int jk = (j - 1) * number_of_beads + k;
      double pi_factor = 2.0 * PI * j * k / number_of_beads;
      if (k == 0) {
        transformation_matrix_cpu[jk] = sqrt_factor_1;
      } else if (k < number_of_beads / 2) {
        transformation_matrix_cpu[jk] = sqrt_factor_2 * cos(pi_factor);
      } else if (k == number_of_beads / 2) {
        transformation_matrix_cpu[jk] = sqrt_factor_1 * sign_factor;
      } else {
        transformation_matrix_cpu[jk] = sqrt_factor_2 * sin(pi_factor);
      }
    }
  }
  transformation_matrix.copy_from_host(transformation_matrix_cpu.data());

  curand_states.resize(number_of_atoms);
  int grid_size = (number_of_atoms - 1) / 128 + 1;
  initialize_curand_states<<<grid_size, 128>>>(curand_states.data(), number_of_atoms, rand());
  CUDA_CHECK_KERNEL
}

Ensemble_PIMD::~Ensemble_PIMD(void)
{
  // nothing
}

static __global__ void gpu_nve_1(
  const int number_of_atoms,
  const int number_of_beads,
  Ensemble_PIMD::Beads beads,
  const double omega_n,
  const double time_step,
  const double* transformation_matrix,
  const double* g_mass)
{
  int n = blockIdx.x * blockDim.x + threadIdx.x;
  if (n < number_of_atoms) {
    const double half_time_step = time_step * 0.5;
    double factor = half_time_step / g_mass[n];
    for (int k = 0; k < number_of_beads; ++k) {
      beads.velocity[k][n] += factor * beads.force[k][n];
    }

    double velocity_normal[128];
    double position_normal[128];
    for (int k = 0; k < number_of_beads; ++k) {
      double temp_velocity = 0.0;
      double temp_position = 0.0;
      for (int j = 0; j < number_of_beads; ++j) {
        temp_velocity += beads.velocity[j][n] * transformation_matrix[j * number_of_beads + k];
        temp_position += beads.position[j][n] * transformation_matrix[j * number_of_beads + k];
      }
      velocity_normal[k] = temp_velocity;
      position_normal[k] = temp_position;
    }

    position_normal[0] += velocity_normal[0] * time_step; // special case of k=0
    for (int k = 1; k < number_of_beads; ++k) {
      double omega_k = omega_n * sin(k * PI / number_of_beads);
      double cos_factor = cos(omega_k * time_step);
      double sin_factor = sin(omega_k * time_step);
      double sin_factor_times_omega = sin_factor * omega_k;
      double sin_factor_over_omega = sin_factor / omega_k;
      double vel = velocity_normal[k];
      double pos = position_normal[k];
      velocity_normal[k] = cos_factor * vel - sin_factor_times_omega * pos;
      position_normal[k] = sin_factor_over_omega * vel + cos_factor * pos;
    }

    for (int j = 0; j < number_of_beads; ++j) {
      double temp_velocity = 0.0;
      double temp_position = 0.0;
      for (int k = 0; k < number_of_beads; ++k) {
        temp_velocity += velocity_normal[k] * transformation_matrix[j * number_of_beads + k];
        temp_position += position_normal[k] * transformation_matrix[j * number_of_beads + k];
      }
      beads.velocity[j][n] = temp_velocity;
      beads.position[j][n] = temp_position;
    }
  }
}

static __global__ void gpu_nve_2(
  const int number_of_atoms,
  const int number_of_beads,
  Ensemble_PIMD::Beads beads,
  const double time_step,
  const double* g_mass)
{
  int n = blockIdx.x * blockDim.x + threadIdx.x;
  if (n < number_of_atoms) {
    const double half_time_step = time_step * 0.5;
    double factor = half_time_step / g_mass[n];
    for (int k = 0; k < number_of_beads; ++k) {
      beads.velocity[k][n] += factor * beads.force[k][n];
    }
  }
}

static __global__ void gpu_langevin(
  const int number_of_atoms,
  const int number_of_beads,
  Ensemble_PIMD::Beads beads,
  curandState* g_state,
  const double temperature,
  const double temperature_coupling,
  const double omega_n,
  const double time_step,
  const double* transformation_matrix,
  const double* g_mass)
{
  int n = blockIdx.x * blockDim.x + threadIdx.x;
  if (n < number_of_atoms) {
    double velocity_normal[128];
    for (int k = 0; k < number_of_beads; ++k) {
      double temp_velocity = 0.0;
      for (int j = 0; j < number_of_beads; ++j) {
        temp_velocity += beads.velocity[j][n] * transformation_matrix[j * number_of_beads + k];
      }
      velocity_normal[k] = temp_velocity;
    }

    curandState state = g_state[n];
    for (int k = 0; k < number_of_beads; ++k) {
      double gamma_k = omega_n * sin(k * PI / number_of_beads);
      double exp_factor = -0.5 * time_step * gamma_k;
      if (k == 0 && temperature_coupling <= 100000.0f) {
        exp_factor = -0.5 / temperature_coupling;
      }
      double c1 = exp(exp_factor);
      double c2 = sqrt((1 - c1 * c1) * K_B * temperature * number_of_beads / g_mass[n]);
      for (int d = 0; d < 3; ++d) {
        beads.velocity[k][n + number_of_atoms * d] =
          c1 * beads.velocity[k][n + number_of_atoms * d] + c2 * CURAND_NORMAL(&state);
      }
    }
    g_state[n] = state;

    for (int j = 0; j < number_of_beads; ++j) {
      double temp_velocity = 0.0;
      for (int k = 0; k < number_of_beads; ++k) {
        temp_velocity += velocity_normal[k] * transformation_matrix[j * number_of_beads + k];
      }
      beads.velocity[j][n] = temp_velocity;
    }
  }
}

void Ensemble_PIMD::compute1(
  const double time_step,
  const std::vector<Group>& group,
  Box& box,
  Atom& atom,
  GPU_Vector<double>& thermo)
{
  gpu_langevin<<<(number_of_atoms - 1) / 64 + 1, 64>>>(
    number_of_atoms, number_of_beads, beads, curand_states.data(), temperature,
    temperature_coupling, omega_n, time_step, transformation_matrix.data(), atom.mass.data());
  CUDA_CHECK_KERNEL

  gpu_nve_1<<<(number_of_atoms - 1) / 64 + 1, 64>>>(
    number_of_atoms, number_of_beads, beads, omega_n, time_step, transformation_matrix.data(),
    atom.mass.data());
  CUDA_CHECK_KERNEL
}

void Ensemble_PIMD::compute2(
  const double time_step,
  const std::vector<Group>& group,
  Box& box,
  Atom& atom,
  GPU_Vector<double>& thermo)
{
  gpu_nve_2<<<(number_of_atoms - 1) / 64 + 1, 64>>>(
    number_of_atoms, number_of_beads, beads, time_step, atom.mass.data());
  CUDA_CHECK_KERNEL

  gpu_langevin<<<(number_of_atoms - 1) / 64 + 1, 64>>>(
    number_of_atoms, number_of_beads, beads, curand_states.data(), temperature,
    temperature_coupling, omega_n, time_step, transformation_matrix.data(), atom.mass.data());
  CUDA_CHECK_KERNEL

  // TODO: correct momentum

  // get averaged quantities

  find_thermo(
    true, box.get_volume(), group, atom.mass, atom.potential_per_atom, atom.velocity_per_atom,
    atom.virial_per_atom, thermo);
}
