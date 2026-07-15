/***********************************************************************\
 * This software is licensed under the terms of the GNU General Public *
 * License version 3 or later. See G4CMP/LICENSE for the full license. *
\***********************************************************************/

/// \file quasiparticle/quasiparticle.cc
/// \brief Main program of the G4CMP/quasiparticle example
//
// $Id$
//

#include "G4RunManager.hh"
#include "G4UIExecutive.hh"
#include "G4UImanager.hh"
#include "G4VisExecutive.hh"

#include "G4CMPPhysicsList.hh"
#include "G4CMPConfigManager.hh"
#include "QuasiparticleActionInitialization.hh"
#include "QuasiparticleConfigManager.hh"
#include "QuasiparticleDetectorConstruction.hh"
#include "QuasiparticleDetectorParameters.hh"

int main(int argc,char** argv)
{
 // Construct the run manager
 //
 G4RunManager * runManager = new G4RunManager;

 // Prefer project-local lattice overrides, while retaining the configured
 // G4CMP lattice directory for every material without an override.
 // This works around newer G4CMP releases trying to derive semiconductor
 // charge-scattering parameters for superconducting metal lattices.
 G4String latticePath = G4String(QP_SOURCE_DIR) + "/CrystalMaps";
 const G4String configuredLatticePath = G4CMPConfigManager::GetLatticeDir();
 if (!configuredLatticePath.empty()) latticePath += ":" + configuredLatticePath;
 G4CMPConfigManager::SetLatticeDir(latticePath);

 // Set mandatory initialization classes
 //
 QuasiparticleDetectorConstruction* detector = new QuasiparticleDetectorConstruction();
 runManager->SetUserInitialization(detector);

 G4VUserPhysicsList* physics = new G4CMPPhysicsList();
 physics->SetCuts();
 runManager->SetUserInitialization(physics);

 // Set user action classes (different for Geant4 10.0)
 //
 runManager->SetUserInitialization(new QuasiparticleActionInitialization);

 // Create configuration managers to ensure macro commands exist
 G4CMPConfigManager::Instance();
 QuasiparticleConfigManager::Instance();

 // Visualization manager
 //
 G4VisManager* visManager = new G4VisExecutive;
 visManager->Initialize();
 
 // Get the pointer to the User Interface manager
 //
 G4UImanager* UImanager = G4UImanager::GetUIpointer();  

 if (argc==1)   // Define UI session for interactive mode
 {
      G4UIExecutive * ui = new G4UIExecutive(argc,argv);
      ui->SessionStart();
      delete ui;
 }
 else           // Batch mode
 {
   G4String command = "/control/execute ";
   G4String fileName = argv[1];
   UImanager->ApplyCommand(command+fileName);
 }

 delete visManager;
 delete runManager;

 return 0;
}
