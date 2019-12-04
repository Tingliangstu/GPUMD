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
The Berendsen thermostat:
[1] H. J. C. Berendsen et al. J. Chem. Phys. 81, 3684 (1984).
------------------------------------------------------------------------------*/


#include "ensemble_ber.cuh"
#include "force.cuh"
#include "atom.cuh"
#include "error.cuh"

#define BLOCK_SIZE 128


Ensemble_BER::Ensemble_BER(int t, int fg, real T, real Tc)
{
    type = t;
    fixed_group = fg;
    temperature = T;
    temperature_coupling = Tc;
}


Ensemble_BER::Ensemble_BER
(
    int t, int fg, real T, real Tc, real px, real py, real pz, real pc,
    int dx, int dy, int dz, real rate
)
{
    type = t;
    fixed_group = fg;
    temperature = T;
    temperature_coupling = Tc;
    pressure_x = px;
    pressure_y = py;
    pressure_z = pz;
    pressure_coupling = pc;
    deform_x = dx;
    deform_y = dy;
    deform_z = dz;
    deform_rate = rate;
}


Ensemble_BER::~Ensemble_BER(void)
{
    // nothing now
}


static __global__ void gpu_berendsen_temperature
(
    int N, real temperature, real coupling, real *g_prop, 
    real *g_vx, real *g_vy, real *g_vz
)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < N)
    {  
        real factor = sqrt(ONE + coupling * (temperature / g_prop[0] - ONE)); 
        g_vx[i] *= factor; 
        g_vy[i] *= factor; 
        g_vz[i] *= factor;
    }
}


static __global__ void gpu_berendsen_pressure
(
    int deform_x, int deform_y, int deform_z, real deform_rate,
    int number_of_particles, Box box,
    real p0x, real p0y, real p0z, real p_coupling, 
    real *g_prop, real *g_x, real *g_y, real *g_z
)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < number_of_particles)
    {
        if (deform_x)
        {
            real scale_factor = box.cpu_h[0];
            scale_factor = (scale_factor + deform_rate) / scale_factor;
            g_x[i] *= scale_factor;
        }
        else if (box.pbc_x == 1)
        {
            real scale_factor = ONE - p_coupling * (p0x - g_prop[2]);
            g_x[i] *= scale_factor;
        }
        if (deform_y)
        {
            real scale_factor = box.cpu_h[1];
            scale_factor = (scale_factor + deform_rate) / scale_factor;
            g_y[i] *= scale_factor;
        }
        else if (box.pbc_y == 1)
        {
            real scale_factor = ONE - p_coupling * (p0y - g_prop[3]);
            g_y[i] *= scale_factor;
        }
        if (deform_z)
        {
            real scale_factor = box.cpu_h[2];
            scale_factor = (scale_factor + deform_rate) / scale_factor;
            g_z[i] *= scale_factor;
        }
        else if (box.pbc_z == 1)
        {
            real scale_factor = ONE - p_coupling * (p0z - g_prop[4]);
            g_z[i] *= scale_factor;
        }
    }
}


static void cpu_berendsen_pressure
(
    int deform_x, int deform_y, int deform_z, real deform_rate, Box& box,
    real p0x, real p0y, real p0z, real p_coupling, real *thermo
)
{
    real *p; MY_MALLOC(p, real, 3);
    CHECK(cudaMemcpy(p, thermo+2, sizeof(real)*3, cudaMemcpyDeviceToHost));

    if (deform_x)
    {
        real scale_factor = box.cpu_h[0];
        scale_factor = (scale_factor + deform_rate) / scale_factor;
        box.cpu_h[0] *= scale_factor;
        box.cpu_h[3] = box.cpu_h[0] * HALF;
    }
    else if (box.pbc_x == 1)
    {
        real scale_factor = ONE - p_coupling * (p0x - p[0]);
        box.cpu_h[0] *= scale_factor;
        box.cpu_h[3] = box.cpu_h[0] * HALF;
    }

    if (deform_y)
    {
        real scale_factor = box.cpu_h[1];
        scale_factor = (scale_factor + deform_rate) / scale_factor;
        box.cpu_h[1] *= scale_factor;
        box.cpu_h[4] = box.cpu_h[1] * HALF;
    }
    else if (box.pbc_y == 1)
    {
        real scale_factor = ONE - p_coupling * (p0y - p[1]);
        box.cpu_h[1] *= scale_factor;
        box.cpu_h[4] = box.cpu_h[1] * HALF;
    }

    if (deform_z)
    {
        real scale_factor = box.cpu_h[2];
        scale_factor = (scale_factor + deform_rate) / scale_factor;
        box.cpu_h[2] *= scale_factor;
        box.cpu_h[5] = box.cpu_h[2] * HALF;
    }
    else if (box.pbc_z == 1)
    {
        real scale_factor = ONE - p_coupling * (p0x - p[2]);
        box.cpu_h[2] *= scale_factor;
        box.cpu_h[5] = box.cpu_h[2] * HALF;
    }

    MY_FREE(p);
}


void Ensemble_BER::compute(Atom *atom, Force *force, Measure* measure)
{
    int grid_size = (atom->N - 1) / BLOCK_SIZE + 1;
    velocity_verlet(atom, force, measure);
    find_thermo(atom);
    gpu_berendsen_temperature<<<grid_size, BLOCK_SIZE>>>
    (
        atom->N, temperature, temperature_coupling, atom->thermo,
        atom->vx, atom->vy, atom->vz
    );
    CUDA_CHECK_KERNEL
    if (type == 11)
    {
        gpu_berendsen_pressure<<<grid_size, BLOCK_SIZE>>>
        (
            deform_x, deform_y, deform_z, deform_rate, atom->N,
            atom->box, pressure_x, 
            pressure_y, pressure_z, pressure_coupling, atom->thermo,
            atom->x, atom->y, atom->z
        );
        CUDA_CHECK_KERNEL
        cpu_berendsen_pressure
        (
            deform_x, deform_y, deform_z, deform_rate, atom->box, pressure_x,
            pressure_y, pressure_z, pressure_coupling, atom->thermo
        );
    }
}


