/q tick/r.q [host]:port[:usr:pwd] [host]:port[:usr:pwd]
/2008.09.09 .k ->.q

if[not "w"=first string .z.o;system "sleep 1"];

upd:insert;

/ get the ticker plant and history ports
.u.x:2#.z.x;

.u.addLookup:{`:lookup/ upsert .Q.en[`:.] raze {select part:enlist x,tab:enlist y,minTS:min time,maxTS:max time from y}[x] each tables[]};

k)saveAndReload:{[h;d;p;f](@[`.;;0#].Q.dpft[d;p;f]@)'t@>(#.:)'t:.q.tables`.;if[h:@[hopen;h;0];h"system\"l .\";cacheLookup[]";>h]};

/ end of day: save, clear, hdb reload
.u.end:{t:tables`.;t@:where `g=attr each t@\:`sym;.u.addLookup[x];saveAndReload[`$":",.u.x 1;`:.;x;`sym];@[;`sym;`g#] each t;};

/ init schema and sync up from log file;cd to hdb(so client save can run)
.u.rep:{(.[;();:;].)each x;if[null first y;:()];-11!y;system "cd ",.z.x 2};
/ HARDCODE \cd if other than logdir/db

/ connect to ticker plant for (schema;(logcount;log))
.u.rep .(hopen `$":",.u.x 0)"(.u.sub[`;`];`.u `i`L)";

