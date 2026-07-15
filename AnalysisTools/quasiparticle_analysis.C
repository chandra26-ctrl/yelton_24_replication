/***********************************************************************\
 * This software is licensed under the terms of the GNU General Public *
 * License version 3 or later. See G4CMP/LICENSE for the full license. *
\***********************************************************************/

//------------------------------------------------------------------
//
// quasiparticle_analysis.C
//
// Analyze the compact CSV output produced by QuasiparticleSteppingAction:
// Event,Track,Parent,Patch,Creation Time [ns],Death Time [ns]
//
//------------------------------------------------------------------

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "TDirectory.h"
#include "TFile.h"
#include "TH1I.h"

namespace {

struct QuasiparticleRecord {
  int eventID;
  int trackID;
  int parentID;
  std::string patch;
  double creationTime_ns;
  double deathTime_ns;
};

std::string Trim(const std::string& input) {
  const std::string whitespace = " \t\r\n";
  const std::string::size_type first = input.find_first_not_of(whitespace);
  if (first == std::string::npos) return "";
  const std::string::size_type last = input.find_last_not_of(whitespace);
  return input.substr(first, last - first + 1);
}

bool ParseInt(const std::string& text, int& value) {
  char* end = 0;
  const long parsed = std::strtol(text.c_str(), &end, 10);
  if (end == text.c_str() || *end != '\0') return false;
  value = static_cast<int>(parsed);
  return true;
}

bool ParseDouble(const std::string& text, double& value) {
  char* end = 0;
  value = std::strtod(text.c_str(), &end);
  return end != text.c_str() && *end == '\0' && std::isfinite(value);
}

std::vector<std::string> SplitCSVLine(const std::string& line) {
  std::vector<std::string> fields;
  std::stringstream stream(line);
  std::string field;
  while (std::getline(stream, field, ',')) fields.push_back(Trim(field));
  return fields;
}

std::vector<QuasiparticleRecord> ReadQuasiparticleFile(
    const std::string& filename) {
  std::vector<QuasiparticleRecord> records;
  std::ifstream input(filename.c_str());
  if (!input.is_open()) {
    std::cerr << "Error: could not open quasiparticle file '" << filename
              << "'." << std::endl;
    return records;
  }

  std::string line;
  unsigned long lineNumber = 0;
  while (std::getline(input, line)) {
    ++lineNumber;
    line = Trim(line);
    if (line.empty()) continue;

    const std::vector<std::string> fields = SplitCSVLine(line);
    if (!fields.empty() && fields[0] == "Event") continue;
    if (fields.size() != 6) {
      std::cerr << "Warning: skipping line " << lineNumber << " in '"
                << filename << "' (expected 6 CSV fields, found "
                << fields.size() << ")." << std::endl;
      continue;
    }

    QuasiparticleRecord record;
    record.patch = fields[3];
    if (!ParseInt(fields[0], record.eventID) ||
        !ParseInt(fields[1], record.trackID) ||
        !ParseInt(fields[2], record.parentID) ||
        !ParseDouble(fields[4], record.creationTime_ns) ||
        !ParseDouble(fields[5], record.deathTime_ns)) {
      std::cerr << "Warning: skipping malformed values on line " << lineNumber
                << " in '" << filename << "'." << std::endl;
      continue;
    }
    records.push_back(record);
  }

  std::cout << "Read " << records.size() << " quasiparticles from "
            << filename << std::endl;
  return records;
}

void WriteCreationHistograms(TFile& output,
                             const std::vector<QuasiparticleRecord>& records,
                             const std::string& directoryName,
                             int numberOfTimeBins) {
  TDirectory* directory = output.mkdir(directoryName.c_str());
  if (!directory) {
    std::cerr << "Error: could not create ROOT directory '" << directoryName
              << "'." << std::endl;
    return;
  }
  directory->cd();

  if (records.empty()) {
    std::cerr << "Warning: no valid quasiparticles for " << directoryName
              << "; no histograms were written." << std::endl;
    output.cd();
    return;
  }

  if (numberOfTimeBins < 1) numberOfTimeBins = 1;
  double maximumTime_ns = 0.0;
  for (std::vector<QuasiparticleRecord>::const_iterator it = records.begin();
       it != records.end(); ++it) {
    maximumTime_ns = std::max(maximumTime_ns, it->creationTime_ns);
  }
  // Leave a small amount of headroom so the latest QP does not land exactly
  // on the upper edge. Use 1 ns for an all-zero-time input.
  maximumTime_ns = maximumTime_ns > 0.0 ? maximumTime_ns * 1.000001 : 1.0;

  TH1I createdPerTimeBin(
      "h_qpCreatedCountVsTimeBin",
      "Quasiparticle creation versus time;Creation time [ns];Number of quasiparticles created",
      numberOfTimeBins, 0.0, maximumTime_ns);
  for (std::vector<QuasiparticleRecord>::const_iterator it = records.begin();
       it != records.end(); ++it) {
    createdPerTimeBin.Fill(it->creationTime_ns);
  }

  // Store the primary name used by the requested plot and retain the older
  // descriptive name as an alias for compatibility.
  createdPerTimeBin.Write();
  createdPerTimeBin.Write("h_qpCreatedPerTimeBin");
  output.cd();
}

}  // namespace

// Read two simulation CSV files and store their histograms in separate ROOT
// directories. numberOfTimeBins may be omitted when calling this from ROOT.
void run_quasiparticle_analysis(std::string infilePoint1,
                                std::string infilePoint2,
                                int numberOfTimeBins = 200) {
  if (numberOfTimeBins < 1) {
    std::cerr << "Error: numberOfTimeBins must be positive." << std::endl;
    return;
  }

  TFile output("quasiparticle_analysis_output.root", "RECREATE");
  if (output.IsZombie()) {
    std::cerr << "Error: could not create quasiparticle_analysis_output.root."
              << std::endl;
    return;
  }

  WriteCreationHistograms(output, ReadQuasiparticleFile(infilePoint1),
                          "Point1", numberOfTimeBins);
  WriteCreationHistograms(output, ReadQuasiparticleFile(infilePoint2),
                          "Point2", numberOfTimeBins);
  output.Write();
  output.Close();

  std::cout << "Wrote quasiparticle_analysis_output.root" << std::endl;
}
