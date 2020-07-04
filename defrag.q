RDB:`$.z.x[0];
HDB:`$.z.x[1];

defrag:{[hdb;src;dst;comp;p;typ]
 system"l ",1_string hdb;
 .z.zd:comp;
 defragTab[src;dst;comp;p] peach .Q.pt;
 $[typ=`hourly;HDB(reloadHourly;src;dst);RDB (reloadFixed;src;dst)];
 };

defragTab:{[src;dst;comp;p;t]
 ps:?[t;();1b;enlist[p]!enlist[p]]p;
 {[src;dst;t;p]
  path:.Q.dd[`$":._tmp_",string dst;t,`];
  d:select from t where int in src,sym=p;
  path upsert d;
  }[src;dst;t] each ps;
 applyP[dst;t;p];
 };

applyP:{[dst;t;p]
 .[.Q.dd[`$":._tmp_",string dst;t,p];();`p#];
 };

reloadHourly:{[src;dst]
  {system"rm -r ",string x} each src;
  dst:string dst;
  system"mv ._tmp_",dst," ",dst;
  system"l .";
 };

reloadFixed:{[src;dst]
 lookup:select from `:lookup/;
 newInfo:raze {[l;s;d;t]
    select part:enlist d,tab:enlist t,
     minTS:min minTS,
     maxTS:max maxTS from l where part in s}[lookup;src;dst] each tables[];
 `:lookup/ set .Q.en[`:.] `part`tab xasc newInfo,delete from lookup where part in src;
 reload:{[src;dst]
  {system"rm -r ",string x} each src;
  dst:string dst;
  system"mv ._tmp_",dst," ",dst;
  system"l .";
  cacheLookup[]};
  (`$":",.u.x 1) (reload;src;dst);
 };
