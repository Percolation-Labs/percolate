q 'GRAPH "Ana Costa"' | jq -r '.rows[] | "\(.relation)\t\(.key)"' | sort
