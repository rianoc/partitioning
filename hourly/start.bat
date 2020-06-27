start "tick" q tick.q sym .             -p 5010
start "RDB"  q tick/r.q :5010 :5012 HDB -p 5011
start "HDB"  q HDB                      -p 5012
start "feed" q ../feed.q :5010