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
    GNU General Public License for more details. You should have received a copy of the GNU General
   Public License along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/

/*-----------------------------------------------------------------------------------------------100
Dump energy/force/virial with all loaded potentials at a given interval.
--------------------------------------------------------------------------------------------------*/

#include "cavity.cuh"
#include "nep3_cavity.cuh"
#include "potential_cavity.cuh"
#include "model/box.cuh"
#include "model/read_xyz.cuh"
#include "utilities/common.cuh"
#include "utilities/error.cuh"
#include "utilities/gpu_vector.cuh"
#include "utilities/read_file.cuh"
#include <iostream>
#include <vector>


const double BOHR_IN_ANGSTROM = 0.529177249;

static __global__ void sum_dipole(
  const int N, const int number_of_patches, const double* g_virial_per_atom, double* g_dipole)
{
  //<<<3, 1024>>>
  int tid = threadIdx.x;
  int bid = blockIdx.x;
  __shared__ double s_d[1024];
  double d = 0.0;

  const unsigned int componentIdx = blockIdx.x * N;

  // 1024 threads, each summing a patch of N/1024 atoms
  for (int patch = 0; patch < number_of_patches; ++patch) {
    int atomIdx = tid + patch * 1024;
    if (atomIdx < N)
      d += g_virial_per_atom[componentIdx + atomIdx];
  }

  // save the sum for this patch
  s_d[tid] = d;
  __syncthreads();

  // aggregate the patches in parallel
#pragma unroll
  for (int offset = blockDim.x >> 1; offset > 32; offset >>= 1) {
    if (tid < offset) {
      s_d[tid] += s_d[tid + offset];
    }
    __syncthreads();
  }
  for (int offset = 32; offset > 0; offset >>= 1) {
    if (tid < offset) {
      s_d[tid] += s_d[tid + offset];
    }
    __syncwarp();
  }

  // save the final value
  if (tid == 0) {
    g_dipole[bid] = s_d[0];
  }
}


static __global__ void get_center_of_mass(
  const int N, 
  const int number_of_patches, 
  const double total_mass,
  const double* g_mass_per_atom,  
  const double* g_position_per_atom,
  double* g_center_of_mass)
{
  //<<<3, 1024>>>
  int tid = threadIdx.x;
  int bid = blockIdx.x;
  __shared__ double s_d[1024];
  double d = 0.0;

  const unsigned int componentIdx = bid * N;

  // 1024 threads, each summing a patch of N/1024 atoms
  for (int patch = 0; patch < number_of_patches; ++patch) {
    int atomIdx = tid + patch * 1024;
    if (atomIdx < N) {
      d += g_mass_per_atom[atomIdx] * g_position_per_atom[componentIdx + atomIdx];
    }
  }

  // save the sum for this patch
  s_d[tid] = d;
  __syncthreads();

  // aggregate the patches in parallel
  #pragma unroll
  for (int offset = blockDim.x >> 1; offset > 32; offset >>= 1) {
    if (tid < offset) {
      s_d[tid] += s_d[tid + offset];
    }
    __syncthreads();
  }
  for (int offset = 32; offset > 0; offset >>= 1) {
    if (tid < offset) {
      s_d[tid] += s_d[tid + offset];
    }
    __syncwarp();
  }

  // save the final value
  if (tid == 0) {
    g_center_of_mass[bid] = s_d[0] / total_mass;
  }
}

static __global__ void copy_mass_and_type_to_cavity(
  const int N,
  const double* ref_g_mass,
  const int* ref_g_type,
  double* g_mass,
  int* g_type)
{
  // Copy mass and type to the twelve copies 
  // of the system in AtomCavity
  int n1 = blockIdx.x * blockDim.x + threadIdx.x;
  if (n1 < N) {
    for (int i = 0; i < 12; i++) {
      g_mass[n1 + i * N] = ref_g_mass[n1];
      g_type[n1 + i * N] = ref_g_type[n1];
    }
  }
}


static __global__ void copy_positions(
  const int N,
  const double* ref_g_p,
  double* g_p)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x;
  if (n1 < N) {
    // Copy the atom positions
    g_p[n1 + 0 * N] = ref_g_p[n1 + 0 * N];
    g_p[n1 + 1 * N] = ref_g_p[n1 + 1 * N];
    g_p[n1 + 2 * N] = ref_g_p[n1 + 2 * N];
  }
}

static __global__ void apply_cavity_force(
  int N,
  double* g_force,
  double* g_cav_force)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x;
  if (n1 < N) {
    // apply the cavity force to the existing forces
    // from the PES. 
    g_force[n1 + 0 * N] += g_cav_force[n1 + 0 * N];
    g_force[n1 + 1 * N] += g_cav_force[n1 + 1 * N];
    g_force[n1 + 2 * N] += g_cav_force[n1 + 2 * N];
  }
}


static __global__ void initialize_properties(
  int N,
  double* g_fx,
  double* g_fy,
  double* g_fz,
  double* g_pe,
  double* g_virial)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x;
  if (n1 < N) {
    g_fx[n1] = 0.0;
    g_fy[n1] = 0.0;
    g_fz[n1] = 0.0;
    g_pe[n1] = 0.0;
    g_virial[n1 + 0 * N] = 0.0;
    g_virial[n1 + 1 * N] = 0.0;
    g_virial[n1 + 2 * N] = 0.0;
    g_virial[n1 + 3 * N] = 0.0;
    g_virial[n1 + 4 * N] = 0.0;
    g_virial[n1 + 5 * N] = 0.0;
    g_virial[n1 + 6 * N] = 0.0;
    g_virial[n1 + 7 * N] = 0.0;
    g_virial[n1 + 8 * N] = 0.0;
  }
}


Cavity::Cavity(void)
{
  // do nothing
  // This is needed here for some reason
  // due to the NEP3Cavity instance variable.
  // It is probably a complex type that the compiler
  // expects to require a constructor or something.
}

void Cavity::parse(
    const char** param, 
    int num_param, 
    int number_of_atoms)
{
  enabled_ = true;
  printf("Cavity dynamics\n");
  
  FILE* fid_potential = my_fopen(param[1], "r");
  char potential_name[100];
  int count = fscanf(fid_potential, "%s", potential_name);
  if (count != 1) {
    PRINT_INPUT_ERROR("reading error for potential file.");
  }
  // Set up the potential for calculating dipoles with double precision
  number_of_atoms_ = number_of_atoms;
  potential.reset(new NEP3Cavity(param[1], number_of_atoms));
  potential->N1 = 0;
  potential->N2 = number_of_atoms;
  // and the potential for the jacobian batch calculations
  number_of_copied_systems_ = 12*number_of_atoms_;
  number_of_atoms_in_copied_system_ = number_of_copied_systems_ * number_of_atoms_;
  potential_jacobian.reset(new NEP3Cavity(param[1], number_of_atoms_in_copied_system_));
  potential_jacobian->N1 = 0;
  potential_jacobian->N2 = number_of_atoms_in_copied_system_;

  if (num_param != 5) {
    PRINT_INPUT_ERROR("cavity should have 4 parameters.");
  }
  if (!is_valid_real(param[2], &coupling_strength)) {
    PRINT_INPUT_ERROR("coupling strength should be a real number.");
  }
  if (coupling_strength < 0.0) {
    PRINT_INPUT_ERROR("coupling strength cannot be negative.");
  }

  if (!is_valid_real(param[3], &cavity_frequency)) {
    PRINT_INPUT_ERROR("cavity frequency should be a real number.");
  }
  if (cavity_frequency < 0.0) {
    PRINT_INPUT_ERROR("cavity frequency cannot be negative.");
  }
  if (!is_valid_int(param[4], &charge)) {
    PRINT_INPUT_ERROR("total system charge should be an integer.");
  }
  printf("   coupling strength %f.\n", coupling_strength);
printf("   cavity frequency %f.\n", cavity_frequency);
printf("   total charge %d.\n", charge);
}

void Cavity::initialize(
Box& box,
Atom& atom,
Force& force)
{
// Setup a dump_exyz with the dump_interval for dump_observer.
if (enabled_) {
  const int number_of_potentials = force.potentials.size();
  std::string jac_filename_ = "jacobian.out";
  std::string cav_filename_ = "cavity.out";
  jacfile_ = my_fopen(jac_filename_.c_str(), "a");
  cavfile_ = my_fopen(cav_filename_.c_str(), "a");
  prevdipole.resize(3);
  cpu_dipole_.resize(3);
  cpu_dipole_jacobian_.resize(number_of_atoms_ * 3 * 3);
  cpu_cavity_force_.resize(number_of_atoms_ * 3);
  gpu_dipole_.resize(3);
  gpu_dipole_jacobian_.resize(number_of_atoms_ * 3 * 3);
  gpu_cavity_force_.resize(number_of_atoms_ * 3);

  // Set up a local copy of the Atoms, on which to compute the dipole
  // Typically in GPUMD we are limited by computational speed, not memory,
  // so we can sacrifice a bit of memory to skip having to recompute the forces
  // & virials with the original potential
  atom_copy.number_of_atoms = number_of_atoms_;
  atom_copy.type.resize(number_of_atoms_);
  atom_copy.mass.resize(number_of_atoms_);
  atom_copy.position_per_atom.resize(number_of_atoms_ * 3);
  atom_copy.force_per_atom.resize(number_of_atoms_ * 3);
  atom_copy.virial_per_atom.resize(number_of_atoms_ * 9);
  atom_copy.potential_per_atom.resize(number_of_atoms_);
  atom_copy.cpu_type.resize(number_of_atoms_);
  atom_copy.cpu_mass.resize(number_of_atoms_);
  atom_copy.cpu_position_per_atom.resize(number_of_atoms_ * 3);

  // Configure the AtomCavity object that will hold all the dipoles
  // for the batched Jacobian calculations
  // This system will have 12*N the number of atoms
  atom_cavity.number_of_atoms = number_of_atoms_in_copied_system_;
  atom_cavity.type.resize(number_of_atoms_in_copied_system_);
  atom_cavity.mass.resize(number_of_atoms_in_copied_system_);
  atom_cavity.position_per_atom.resize(number_of_atoms_in_copied_system_ * 3);
  atom_cavity.force_per_atom.resize(number_of_atoms_in_copied_system_ * 3);
  atom_cavity.virial_per_atom.resize(number_of_atoms_in_copied_system_ * 9);
  atom_cavity.potential_per_atom.resize(number_of_atoms_in_copied_system_);
  atom_cavity.cpu_type.resize(number_of_atoms_in_copied_system_);
  atom_cavity.cpu_mass.resize(number_of_atoms_in_copied_system_);
  atom_cavity.cpu_position_per_atom.resize(number_of_atoms_in_copied_system_ * 3);
  atom_cavity.system_index.resize(number_of_atoms_in_copied_system_);
  atom_cavity.cpu_system_index.resize(number_of_atoms_in_copied_system_);


  // make sure that the second potential is actually a dipole model.
  if (number_of_potentials != 2) {
    PRINT_INPUT_ERROR("cavity requires two potentials to be specified.");
  }
  // Multiple potentials may only be used with NEPs, so we know that
  // the second potential must be an NEP
  if (force.potentials[1]->nep_model_type != 1) {
    PRINT_INPUT_ERROR("cavity requires the second NEP potential to be a dipole model.");
  }

  // Copy the mass array on atoms to the CPU
  // and compute the total mass. Do this on the CPU
  // since we only need to do it once
  masses_.resize(number_of_atoms_);
  for (int i=0; i<number_of_atoms_; i++) {
    double m_i = atom.cpu_mass[i];
    masses_[i] = m_i;
    mass_ += m_i;
  }
  // Transfer the types and masses to our copy of the Atoms objects
  atom_copy.type.copy_from_host(atom.cpu_type.data());
  atom_copy.mass.copy_from_host(atom.cpu_mass.data());
  // repeat this 12 times for the 12 copies of the system
  // in AtomCavity
  copy_mass_and_type_to_cavity<<<(number_of_atoms_ - 1) / 128 + 1, 128>>>(
    number_of_atoms_,
    atom.mass.data(),
    atom.type.data(),
    atom_cavity.mass.data(),
    atom_cavity.type.data());
  CUDA_CHECK_KERNEL

// initialize the cavity stuff
// initial cavity coordinate is equal to
// self._cav_q0 = self.coupling_strength_v @ dipole_v / self.cavity_frequency
// so we need the dipole initially

// TODO clean up
// Update the dipole and the jacobian
// we only need the dipole here, but
// doing one unecessary jacobian calc is
// not too bad. 
compute_dipole_and_jacobian(0, box, atom, force);
// For now, only allow a coupling strength vector in the z-direction.
// TODO should actually be the charge corrected dipole
q0 = coupling_strength * cpu_dipole_[2] / cavity_frequency;
std::cout << "init: " << mass_ << " " << q0  << "\n";

// set initial values
cos_integral = 0.0;
  sin_integral = 0.0;
  prevtime = 0.0;
  std::copy(
      cpu_dipole_.begin(),
      cpu_dipole_.end(),
      prevdipole.begin());
}
}

void Cavity::compute_dipole_and_jacobian(
  int step,
  Box& box,
  Atom& atom,
  Force& force)
{
  if (!enabled_) {
    return;
  }
  // This is probably really bad from a performance perspective
  // and I should remove it and just use the original
  // atoms object.
  // copy positions to the local copy of the atoms object
  copy_positions<<<(number_of_atoms_ - 1) / 128 + 1, 128>>>(
    number_of_atoms_,
    atom.position_per_atom.data(),
    atom_copy.position_per_atom.data());
  CUDA_CHECK_KERNEL

  // Compute the dipole
  // Consider this 
  /* if self.gpumddipole:
      atoms_copy = atoms.copy()
      atoms_copy.set_positions(atoms.get_positions() - atoms.get_center_of_mass())
      gpumd_dipole = (self.calcdipole.get_dipole_moment(atoms_copy) * Bohr +
                      self.charge * atoms.get_center_of_mass())
  */
  get_dipole(box, force);
  gpu_dipole_.copy_to_host(cpu_dipole_.data());
  // The dipole is currently in atomic units.
  // Convert it to the units of the forces, 
  // which are in eV/Å (Bohr -> Å),
  // and subtract the charge times the COM.
  GPU_Vector<double> gpu_center_of_mass(3);
  std::vector<double> cpu_center_of_mass(3);
  _get_center_of_mass(gpu_center_of_mass);
  gpu_center_of_mass.copy_to_host(cpu_center_of_mass.data());

  for (int i = 0; i < 3; i++){
    cpu_dipole_[i] *= BOHR_IN_ANGSTROM;
    cpu_dipole_[i] += charge * cpu_center_of_mass[i];
  }
  // Compute the dipole jacobian
  // The dipole jacobian has already been converted from atomic
  // units to GPUMD units and shifted appropriately.
  get_dipole_jacobian(box, force, 0.001, charge);
}

void Cavity::compute_and_apply_cavity_force(Atom& atom) {
  if (!enabled_) {
    return;
  }
  // Compute the cavity force
  cavity_force();

  // Apply the cavity force
  // apply the cavity force to the original Atom object,
  // not the local copy. This has the effect of adding 
  // the cavity force on top of the regular PES force.
  gpu_cavity_force_.copy_from_host(cpu_cavity_force_.data());
  apply_cavity_force<<<(number_of_atoms_ - 1) / 128 + 1, 128>>>(
    number_of_atoms_,
    atom.force_per_atom.data(),
    gpu_cavity_force_.data());
  CUDA_CHECK_KERNEL
}

void Cavity::update_cavity(const int step, const double global_time) {
  if (!enabled_) {
    return;
  }
  // Make sure that the frequency is in fs
  double time = global_time * TIME_UNIT_CONVERSION; // natural (atomic?) units to fs
  // should be done last after atoms have been moved
  // and dipoles and jacobians have been computed
  step_cavity(time);
  
  // Update all properties
  canonical_position(time);
  canonical_momentum(time);
  cavity_potential_energy();
  cavity_kinetic_energy();
}

void Cavity::write(const int step, const double global_time) {
  if (!enabled_) {
    return;
  }
  // Make sure that the frequency is in fs
  double time = global_time * TIME_UNIT_CONVERSION; // natural (atomic?) units to fs

  // Write properties
  write_dipole(step);
  write_cavity(step, time);
}


void Cavity::get_dipole(
  Box& box,
  Force& force)
{
  initialize_properties<<<(number_of_atoms_ - 1) / 128 + 1, 128>>>(
    number_of_atoms_,
    atom_copy.force_per_atom.data(),
    atom_copy.force_per_atom.data() + number_of_atoms_,
    atom_copy.force_per_atom.data() + number_of_atoms_ * 2,
    atom_copy.potential_per_atom.data(),
    atom_copy.virial_per_atom.data());
  CUDA_CHECK_KERNEL
  
  // Reset the dipole
  cpu_dipole_[0] = 0.0;
  cpu_dipole_[1] = 0.0;
  cpu_dipole_[2] = 0.0;
  gpu_dipole_.copy_from_host(cpu_dipole_.data());

  // Compute the dipole
  potential->compute(
    box,
    atom_copy.type,
    atom_copy.position_per_atom,
    atom_copy.potential_per_atom,
    atom_copy.force_per_atom,
    atom_copy.virial_per_atom);
  
  // Aggregate virial_per_atom into dipole
  const int number_of_threads = 1024;
  const int number_of_atoms_per_thread = (number_of_atoms_ - 1) / number_of_threads + 1;
  sum_dipole<<<3, 1024>>>(
    number_of_atoms_,
    number_of_atoms_per_thread,
    atom_copy.virial_per_atom.data(),
    gpu_dipole_.data());
  CUDA_CHECK_KERNEL
}


void Cavity::_get_center_of_mass(GPU_Vector<double>& gpu_center_of_mass) {
  const int number_of_threads = 1024;
  const int number_of_atoms_per_thread = (number_of_atoms_ - 1) / number_of_threads + 1;
  get_center_of_mass<<<3, 1024>>>(
    number_of_atoms_,
    number_of_atoms_per_thread,
    mass_,
    atom_copy.mass.data(),
    atom_copy.position_per_atom.data(),
    gpu_center_of_mass.data());
  CUDA_CHECK_KERNEL
}


void Cavity::get_dipole_jacobian(
  Box& box,
  Force& force,
  double displacement, 
  double charge) 
{
  /**
   @brief Get dipole gradient through finite differences.
   @details Calculates the dipole gradient, a (N_atoms, 3, 3) tensor for the
   gradients dµ_k/dr_ij, for atom i, Cartesian direction j (x, y, z) and dipole
   moment component k.
   Before computing the gradient the dipoles are corrected using the center of
   mass and the total system charge, supplied via the parameter `charge`.
   @param displacement        Displacement in Å.
   @param charge              Total system charge, used to correct dipoles.
  */
  const int N_cartesian = 3;
  const int N_components = 3;
  const int values_per_atom = N_cartesian * N_components;
  
  // Second order central differences
  // Need to compute four dipoles for each structure, yielding an error O(h^4)
  // Coefficients are defined here:
  // https://en.wikipedia.org/wiki/Finite_difference_coefficient#Central_finite_difference

  // dipole vectors are zeroed in find_dipole, can be allocated here
  GPU_Vector<double> gpu_dipole_forward_one_h(3);
  GPU_Vector<double> gpu_dipole_forward_two_h(3);
  GPU_Vector<double> gpu_dipole_backward_one_h(3);
  GPU_Vector<double> gpu_dipole_backward_two_h(3);
  std::vector<double> dipole_forward_one_h(3);
  std::vector<double> dipole_forward_two_h(3);
  std::vector<double> dipole_backward_one_h(3);
  std::vector<double> dipole_backward_two_h(3);

  // use center of mass to correct for permanent dipole
  GPU_Vector<double> gpu_center_of_mass(3);
  std::vector<double> center_of_mass_forward_one_h(3);
  _get_center_of_mass(gpu_center_of_mass);
  gpu_center_of_mass.copy_to_host(center_of_mass_forward_one_h.data());

  std::vector<double> center_of_mass_forward_two_h(
      center_of_mass_forward_one_h);
  std::vector<double> center_of_mass_backward_one_h(
      center_of_mass_forward_one_h);
  std::vector<double> center_of_mass_backward_two_h(
      center_of_mass_forward_one_h);
  // Positions are in order [x1, ..., xN, y1, ..., yN, ...]
  int displaced_index = 0;
  int reference_index = 0;
  int copy_index = 0;
  double old_center_of_mass = 0.0;
  const double displacement_over_M = displacement / mass_;
  const double one_over_displacement =
      1.0 / displacement; // coefficients are scaled properly

  const double c0 = -1.0 / 12.0; // coefficient for 2h
  const double c1 = 2.0 / 3.0;   // coefficient for h

  // Step 1: Setup the 12N cavity atom system for batched
  // calculation of all dipoles
  // Dipoles will be displaced in the following order:
  std::vector<double> shifts{
    displacement,     // h 
    2*displacement,   // 2h
    -1*displacement,  // -h
    -2*displacement   // -2h
  };
  atom_copy.position_per_atom.copy_to_host(
      atom_copy.cpu_position_per_atom.data());
  int values_per_direction = 4 * number_of_atoms_;
  for (int i = 0; i < N_cartesian; i++) {
    for (int j = 0; j < number_of_atoms_; j++) {
      displaced_index = number_of_atoms_ * i + j; // idx of position to change
      for (int k = 0; k < 4; k++){
        copy_index = values_per_direction * i + j * 4 + k;
        // copy all the atom positions to this copy
        // std::copy(
        //     atom_copy.cpu_position_per_atom.begin(),
        //     atom_copy.cpu_position_per_atom.end(),
        //     atom_cavity.cpu_position_per_atom.begin() 
        //     + copy_index * number_of_atoms_);
        for (int l = 0; l < 3*number_of_atoms_; l++){
          atom_cavity.cpu_position_per_atom[copy_index * number_of_atoms_ + l] = atom_copy.cpu_position_per_atom[l];
        }
        // displace the current atom
        atom_cavity.cpu_position_per_atom[copy_index + displaced_index] += shifts[k];
        // set the copy index for these atoms
        // std::fill(
        //     atom_cavity.cpu_system_index.begin()
        //     + copy_index * number_of_atoms_,
        //     atom_cavity.cpu_system_index.begin()
        //     + (copy_index+1) * number_of_atoms_ - 1,
        //     copy_index);
        for (int l = 0; l < number_of_atoms_; l++){
          atom_cavity.cpu_system_index[copy_index * number_of_atoms_ + l] = copy_index;
        }
      }
    }
  }
  atom_cavity.position_per_atom.copy_from_host(
      atom_cavity.cpu_position_per_atom.data());
  atom_cavity.system_index.copy_from_host(
      atom_cavity.cpu_system_index.data());


  // Step 2: Compute the dipoles in the batched system
  initialize_properties<<<(number_of_atoms_in_copied_system_ - 1) / 128 + 1, 128>>>(
    number_of_atoms_in_copied_system_,
    atom_cavity.force_per_atom.data(),
    atom_cavity.force_per_atom.data() + number_of_atoms_in_copied_system_,
    atom_cavity.force_per_atom.data() + number_of_atoms_in_copied_system_ * 2,
    atom_cavity.potential_per_atom.data(),
    atom_cavity.virial_per_atom.data());
  CUDA_CHECK_KERNEL

  // Compute the dipole
  potential_jacobian->compute_jacobian(
    box,
    atom_cavity.type,
    atom_cavity.position_per_atom,
    atom_cavity.potential_per_atom,
    atom_cavity.force_per_atom,
    atom_cavity.virial_per_atom,
    atom_cavity.system_index);

  // Step 3: Collect all dipoles by iterating through
  // the displacements and summing the dipoles, then
  // then computing the Jacobian.
  for (int i = 0; i < N_cartesian; i++) {
    for (int j = 0; j < number_of_atoms_; j++) {
      displaced_index = number_of_atoms_ * i + j; // idx of position to change
      old_center_of_mass = center_of_mass_forward_one_h[i];
      copy_index = number_of_atoms_ * i + j * 4 + 0;

      // --- Forward displacement
      int forward_one_h_index = (copy_index + 0) * number_of_atoms_;
      center_of_mass_forward_one_h[i] +=
          displacement_over_M * masses_[j];   // center of mass gets moved by
                                              // +h/N in the same direction

      // Step two displacements forward
      int forward_two_h_index = (copy_index + 1) * number_of_atoms_;
      center_of_mass_forward_two_h[i] +=
          2 * displacement_over_M * masses_[j]; // center of mass gest moved by
                                                // +2h/N in the same direction

      // --- Backwards displacement
      int backward_one_h_index = (copy_index + 2) * number_of_atoms_;
      center_of_mass_backward_one_h[i] -= displacement_over_M * masses_[j];

      int backward_two_h_index = (copy_index + 3) * number_of_atoms_;
      center_of_mass_backward_two_h[i] -=
          2 * displacement_over_M * masses_[j];

      for (int k = 0; k < N_components; k++) {
        // cpu_dipole_jacobian_[i * N_components + j * values_per_atom + k] =
        //     (c0 * (dipole_forward_two_h[k] * BOHR_IN_ANGSTROM +
        //            charge * center_of_mass_forward_two_h[k]) +
        //      c1 * (dipole_forward_one_h[k] * BOHR_IN_ANGSTROM +
        //            charge * center_of_mass_forward_one_h[k]) -
        //      c1 * (dipole_backward_one_h[k] * BOHR_IN_ANGSTROM +
        //            charge * center_of_mass_backward_one_h[k]) -
        //      c0 * (dipole_backward_two_h[k] * BOHR_IN_ANGSTROM +
        //            charge * center_of_mass_backward_two_h[k])) *
        //     one_over_displacement;
        //cpu_dipole_jacobian_[i * N_components + j * values_per_atom + k] =
        //    (c0 * (dipole_forward_two_h[k] * BOHR_IN_ANGSTROM) +
        //     c1 * (dipole_forward_one_h[k] * BOHR_IN_ANGSTROM) -
        //     c1 * (dipole_backward_one_h[k] * BOHR_IN_ANGSTROM)-
        //     c0 * (dipole_backward_two_h[k] * BOHR_IN_ANGSTROM)) *
        //    one_over_displacement;
        cpu_dipole_jacobian_[i * N_components + j * values_per_atom + k] = 1.0;
      }
      center_of_mass_forward_one_h[i] = old_center_of_mass;
      center_of_mass_forward_two_h[i] = old_center_of_mass;
      center_of_mass_backward_one_h[i] = old_center_of_mass;
      center_of_mass_backward_two_h[i] = old_center_of_mass;
    }
  }
}

void Cavity::canonical_position(const double time) {
  /* 
    Cavity position coordinate

        q(t) = sin(ω(t-t₀)) Icos - cos(ω(t-t₀)) Isin + q(t₀) cos(ω(t-t₀))

    where

                t
        Icos = ∫  dt' cos(ωt') λ⋅μ
                t₀

    and

                t
        Isin = ∫  dt' sin(ωt') λ⋅μ
                t₀
    
  */
  double phase = cavity_frequency * time;
  q = sin(phase) * cos_integral
      - cos(phase) * sin_integral
      + q0 * cos(phase);
}

void Cavity::canonical_momentum(const double time) {
  /*
      Cavity momentum coordinate

      p(t) = ω cos(ω(t-t₀)) Icos + ω sin(ω(t-t₀)) Isin - q(t₀) ω sin(ω(t-t₀))

      where

              t
      Icos = ∫  dt' cos(ωt') λ⋅μ
              t₀

      and

              t
      Isin = ∫  dt' sin(ωt') λ⋅μ
              t₀
  */
  double phase = cavity_frequency * time;
  p = cavity_frequency * (
      cos(phase) * cos_integral
      + sin(phase) * sin_integral
      - q0 * sin(phase));
}


void Cavity::cavity_potential_energy() {
  /*
     Potential energy of the cavity
        0.5 (ω q(t) - λ⋅μ(t))²
  */
  // For now, only allow a coupling strength vector in the z-direction.
  double coup_times_dip = coupling_strength * cpu_dipole_[2];
  double cav_factor = cavity_frequency * q - coup_times_dip;
  cavity_pot = 0.5 * cav_factor * cav_factor;
}


void Cavity::cavity_kinetic_energy() {
  /*
     Kinetic energy of the cavity
       0.5 p(t)²
  */
  cavity_kin = 0.5 * p * p;
}


void Cavity::cavity_force() {
  /* Force from the cavity 
     get_dipole, get_dipole_jacobian and
     step() should have been run before
     this function.

     This function can be replaced with a kernel
     once the jacobian is no longer the time limiting step.
   */

  // initialize the cavity force
  for (int i = 0; i < 3*number_of_atoms_; i++){
    cpu_cavity_force_[i] = 0.0;
  }

  // njdip_iv = dipole_jacobian_ivv @ self.coupling_strength_v
  // force_iv = njdip_iv * (self.cavity_frequency * self.canonical_position
  //                           - self.coupling_strength_v @ dipole_v)
  double cav_factor = cavity_frequency * q - coupling_strength*cpu_dipole_[2];
  int N_components = 3;
  int values_per_atom = 9;
  for (int j = 0; j < number_of_atoms_; j++){

    // The coupling is non-zero only in the z-direction
    // so we only need to grap the k=2 components. 
    // the jacobian is indexed as
    // [i * N_components + j * values_per_atom + k]
    cpu_cavity_force_[j + 0*number_of_atoms_] = cav_factor*coupling_strength*cpu_dipole_jacobian_[0 * N_components + j * values_per_atom + 2];
    cpu_cavity_force_[j + 1*number_of_atoms_] = cav_factor*coupling_strength*cpu_dipole_jacobian_[1 * N_components + j * values_per_atom + 2];
    cpu_cavity_force_[j + 2*number_of_atoms_] = cav_factor*coupling_strength*cpu_dipole_jacobian_[2 * N_components + j * values_per_atom + 2];
  }
}

void Cavity::step_cavity(double time) {
  /*
    Step the time dependent potential by time dt.
    Should be called after updating the positions
  */
  // TODO
  double dt = time - prevtime;
  double prevlmu = coupling_strength * prevdipole[2];
  double lmu = coupling_strength * cpu_dipole_[2];

  
  // std::cout << time << " " << dt << " " << prevlmu << " " << lmu << " " << cavity_frequency << " " << prevdipole[2] << " " << cpu_dipole_[2] << "\n";
  cos_integral += 0.5 * dt * cos(cavity_frequency * prevtime) * prevlmu;
  sin_integral += 0.5 * dt * sin(cavity_frequency * prevtime) * prevlmu;
  cos_integral += 0.5 * dt * cos(cavity_frequency * time) * lmu;
  sin_integral += 0.5 * dt * sin(cavity_frequency * time) * lmu;

  // Copy current values to previous
  prevtime = time;
  std::copy(
      cpu_dipole_.begin(),
      cpu_dipole_.end(),
      prevdipole.begin());
}


void Cavity::write_dipole(const int step)
{
  // stress components are in Voigt notation: xx, yy, zz, yz, xz, xy
  fprintf(jacfile_, "%d%20.10e%20.10e%20.10e", step, cpu_dipole_[0], cpu_dipole_[1], cpu_dipole_[2]);
  for (int i = 0; i < cpu_dipole_jacobian_.size(); i++) {
    fprintf(jacfile_, "%20.10e", cpu_dipole_jacobian_[i]);
  }
  fprintf(jacfile_, "\n");
  fflush(jacfile_);
}

void Cavity::write_cavity(const int step, const double time)
{
  // stress components are in Voigt notation: xx, yy, zz, yz, xz, xy
  fprintf(cavfile_, "%d%20.10e%20.10e%20.10e%20.10e%20.10e", step, time, q, p, cavity_pot, cavity_kin);
  for (int i = 0; i < cpu_cavity_force_.size(); i++) {
    fprintf(cavfile_, "%20.10e", cpu_cavity_force_[i]);
  }
  fprintf(cavfile_, "\n");
  fflush(cavfile_);
}

void Cavity::finalize()
{
  if (enabled_) {
    fclose(jacfile_);
    fclose(cavfile_);
    enabled_ = false;
  }
}
