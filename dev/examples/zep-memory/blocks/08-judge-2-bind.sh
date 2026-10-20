decide $J "{\"decision\": \"bind\", \"target\": $(jq '.candidates[0].node_id' claim.json)}" \
  'Same surname and initial, a person both times; each is linked to a Tagus Ceramics, and nothing either says conflicts.'
