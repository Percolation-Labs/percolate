for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -s $AGENT/chat -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
    -d '{"model": "ana-assistant", "stream": false, "messages": [{"role": "user", "content":
         "From this month our containers go through Felixstowe, and I am now based in our Porto office. Which port will my next booking use?"}]}' \
    | jq -r '.choices[0].message.content // .' | tr '\n' ' '; echo
done > answers.txt
awk '{r = /Rotterdam/; f = /Felixstowe/; n[r && !f ? "Rotterdam" : f && !r ? "Felixstowe" : "both or neither"]++}
     END {for (k in n) print n[k], k}' answers.txt | sort -rn
