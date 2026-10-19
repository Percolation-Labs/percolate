q "GRAPH \"Ana Costa\" AS OF '2026-03-01'" | jq -r '.rows[] | "\(.relation)\t\(.key)"' | sort
echo ---
q "GRAPH \"Ana Costa\" AS OF '2026-05-01'" | jq -r '.rows[] | "\(.relation)\t\(.key)"' | sort
