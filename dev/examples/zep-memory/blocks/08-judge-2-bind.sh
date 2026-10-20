decide $J "{\"decision\": \"bind\", \"target\": $(jq '.evidence.candidates[0].node_id' claim.json)}" \
  'Both were queued as a person, with the same surname and initial. A. Costa signs "Logistics, Tagus Ceramics" and Ana Costa wrote "Ana Costa of Tagus Ceramics"; nothing either said conflicts.'
