system"l ",.z.x[0];
cacheLookup:{
 if[`lookup in tables[];
 intLookup::.Q.pt!{`lim xasc ungroup select (count[i]*2)#part,lim:{x,y}[minTS;maxTS] from lookup where tab=x} each .Q.pt];
 };
cacheLookup[];

findInts:{[t;s;e] exec distinct part from intLookup[t] where lim within (s;e)};