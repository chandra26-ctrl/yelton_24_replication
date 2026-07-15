/***********************************************************************\
 * This software is licensed under the terms of the GNU General Public *
 * License version 3 or later. See G4CMP/LICENSE for the full license. *
\***********************************************************************/

// 20260109  M. Kelsey -- G4CMP-569: Removed unused local variables


// Basic User Stepping action for Quasiparticle

#include "QuasiparticleSteppingAction.hh"
#include <iostream>
#include <iomanip>
#include "globals.hh"
#include "G4Run.hh"
#include "G4Track.hh"
#include "G4Step.hh"
#include "G4Threading.hh"

#include "G4RunManager.hh"
#include "G4StepPoint.hh"
#include "G4CMPVTrackInfo.hh"
#include "G4CMPTrackUtils.hh"

//....oooOO0OOooo........oooOO0OOooo........oooOO0OOooo........oooOO0OOooo....
//Default constructor
QuasiparticleSteppingAction::QuasiparticleSteppingAction() {
  // One compact record is written when each QP track terminates.
  fOutputFile.open("QuasiparticleStepInformationFile.txt",std::ios::trunc);
  fOutputFile << "Event,Track,Parent,Patch,Creation Time [ns],Death Time [ns]\n";
}

QuasiparticleSteppingAction::~QuasiparticleSteppingAction() {
  fOutputFile.close();
}

//Alternative constructor
void QuasiparticleSteppingAction::UserSteppingAction(const G4Step* step) {
  // check that step is a QP
  std::string particleName =
    step->GetTrack()->GetParticleDefinition()->GetParticleName();
  if (particleName.find("BogoliubovQP") != std::string::npos) {
    ExportStepInformation(step);
  }

  //First up: do generic exporting of step information (no cuts made here)
  //ExportStepInformation(step);
  return;
}

// Do a set of queries of information to test for anharmonic decay
void QuasiparticleSteppingAction::ExportStepInformation(const G4Step* step) {
  const G4Track* track = step->GetTrack();

  // Do no formatting or output work for phonons.
  if (track->GetParticleDefinition()->GetParticleName() != "BogoliubovQP") {
    return;
  }

  const G4int trackID = track->GetTrackID();

  // QPs are secondaries, so GetOriginTouchable() is null.  The first
  // pre-step point does contain the particular physical Al patch.
  if (track->GetCurrentStepNumber() == 1) {
    const G4VPhysicalVolume* creationVolume =
      step->GetPreStepPoint()->GetPhysicalVolume();
    fQPCreationPatch[trackID] =
      creationVolume ? creationVolume->GetName() : "Unknown";
  }

  // Write once, on the terminal step, rather than once per transport step.
  const G4TrackStatus status = track->GetTrackStatus();
  if (status != fStopAndKill && status != fKillTrackAndSecondaries) {
    return;
  }

  const auto patchEntry = fQPCreationPatch.find(trackID);
  const G4String patch = patchEntry != fQPCreationPatch.end()
    ? patchEntry->second : "Unknown";

  const G4double deathTime = step->GetPostStepPoint()->GetGlobalTime();
  const G4double creationTime = deathTime - track->GetLocalTime();
  const G4int eventID =
    G4RunManager::GetRunManager()->GetCurrentEvent()->GetEventID();

  fOutputFile << eventID << ','
              << trackID << ','
              << track->GetParentID() << ','
              << patch << ','
              << std::setprecision(14) << creationTime / CLHEP::ns << ','
              << deathTime / CLHEP::ns << '\n';

  fQPCreationPatch.erase(trackID);
}
