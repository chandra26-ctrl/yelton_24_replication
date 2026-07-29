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
