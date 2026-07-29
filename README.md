# Overview

This project is a modified version of the G4CMP quasiparticle example created to simulate selected results and physical processes described in the 2024 Yelton et al. paper on phonon-mediated quasiparticle poisoning in superconducting qubit arrays.

The original G4CMP example provides the basic framework for simulating phonon propagation, Cooper-pair breaking, and Bogoliubov quasiparticle transport in superconducting materials. I modified that example by changing the device geometry, particle source, material configuration, output tracking, and analysis workflow to more closely resemble the system studied by Yelton et al.

The simulation follows the general physical process described in the paper:
1. Phonons are generated inside or directed toward a silicon substrate.
2. The phonons propagate through the substrate and interact with the device geometry.
3. Phonons that reach the superconducting aluminum structures may break Cooper pairs.
4. The resulting Bogoliubov quasiparticles travel through the aluminum.
5. Quasiparticle creation, movement, and trapping are recorded.
6. The output is processed to estimate the quasiparticle population associated with individual qubits or resonators.

The primary goal of this repository is not to exactly reproduce the result in the paper. Instead, it is to develop a G4CMP model that follows the same general simulation methodology and can be used to investigate how phonons generated in the substrate produce quasiparticles across a superconducting qubit device.

# Important Disclaimer
This repo should not be interpreted as a faithful or exact replication of the Yelton simulation. Several critical parameters needed to reconstruct the original simulation were either not reported in the paper or could not be determined precisely from the publication. Because many of these parameters could not be known, several values and modeling choices in this repo are based on reasonable assumptions, estimates, available G4CMP defaults, or simplified interpretations of the published device.

As a result, this project is best understood as a reproduction of the paper’s general methodology and physical processes rather than a numerically faithful recreation of the authors’ original simulation. Differences between this repository and the published results may arise from unknown parameters, geometry approximations, software-version differences, and assumptions made during implementation.

# Simulation Goals

The modified simulation was developed to study:

-Phonon propagation through a silicon substrate
-Phonon interactions with superconducting aluminum structures
-Cooper-pair breaking caused by sufficiently energetic phonons
-Bogoliubov quasiparticle generation and transport
-Quasiparticle trapping within resonator and qubit structures
-The spatial distribution of quasiparticles across the device
-The relationship between phonon injection location and quasiparticle production
-Quasiparticle populations associated with individual qubits or resonators

A major focus of the analysis is determining how many quasiparticles are produced in different regions of the device after a phonon event and comparing the resulting distributions with the trends presented in the Yelton paper.

# Important files
|file|Purpose|
| --- | --- |
| G4Macros/quasiparticle_geometry_vis.mac | Visualizes the substrate, resonators, qubits, and particle trajectories |
| G4Macros/quasiparticle_resonator_targeted.mac |	Runs the targeted phonon simulation |
| QuasiparticleDetectorConstruction |	Constructs the substrate and superconducting device geometry |
| QuasiparticleDetectorParameters |	Stores dimensions and configurable geometry parameters |
| QuasiparticleResonatorAssembly | Constructs the repeated resonator or qubit structures |
| QuasiparticlePrimaryGeneratorAction |	Configures the phonon or particle source |
| QuasiparticleSteppingAction |	Records relevant phonon and quasiparticle steps |
| QuasiparticleSensitivity |	Records energy deposition and detector-response information |
| AnalysisTools/Xqp.py |	Calculates normalized quasiparticle populations |
| plot_qp_creation_histogram.py	| Produces quasiparticle-creation histograms |
| quasiparticle_analysis.C |	Provides ROOT-based analysis |
| run_parallel.sh |	Divides a simulation across multiple workers |
| run_parallel_phonon_types.sh |	Runs separate simulations for selected phonon polarizations |
| run_process_chunks.sh |	Divides large simulations into independent processes |

# Running the Simulation

Start the executable interactively, by going into the build folder and executing:
> ```
> ./g4cmpQuasiparticle
> ```
There are two build folders, 'QP-build-release' and 'QP-build'. This repository uses two separate build directories for different purposes:

- QP-build is configured with CMake’s RelWithDebInfo build type. It includes compiler optimizations while preserving debugging symbols, making it useful for testing, troubleshooting, and investigating simulation behavior with tools such as GDB.
- QP-build-release is configured with CMake’s Release build type. It enables stronger compiler optimizations and omits most debugging information, making it better suited for large simulations involving millions of phonons.

During development, the regular QP-build directory was used so that errors and unexpected simulation behavior could be debugged more easily. Once the simulation was stable, QP-build-release was used for large production runs to reduce execution time.

At the G4CMP command prompt, execute:
> ```
> /control/execute G4Macros/quasiparticle_geometry_vis.mac
> ```
This macro can be used to inspect the substrate, superconducting structures, resonators, qubits, and particle trajectories. The following geometries compare the cases with and without Cu islands:

[insert figure]

To switch between configurations, toggle the variable `dp_usePaperCuIslands` in the QuasiparticleDetectorParameters header file (line 76): set it to `true` to include Cu islands, or `false` to exclude them.
