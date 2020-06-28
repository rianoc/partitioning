start "tick" q tick.q sym . 5           -p 5010
start "RDB"  q tick/r.q :5010 :5012 HDB -p 5011
start "HDB"  q tick/h.q HDB             -p 5012
start "feed" q ../feed.q :5010