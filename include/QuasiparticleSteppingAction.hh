/***********************************************************************\
 * This software is licensed under the terms of the GNU General Public *
 * License version 3 or later. See G4CMP/LICENSE for the full license. *
\***********************************************************************/

#ifndef QuasiparticleSteppingAction_hh
#define QuasiparticleSteppingAction_hh 1

#include "G4UserSteppingAction.hh"

#include <fstream>
#include <string>
#include <unordered_map>

class G4Step;

class QuasiparticleSteppingAction : public G4UserSteppingAction
{
public:

  QuasiparticleSteppingAction();
  virtual ~QuasiparticleSteppingAction();
  virtual void UserSteppingAction(const G4Step* step);
  void ExportStepInformation( const G4Step * step );
  
private:

  //Step info output file
  std::ofstream fOutputFile;

  // Map a QP track to the physical volume in which its first step starts.
  std::unordered_map<int, std::string> fQPCreationPatch;
};

#endif
