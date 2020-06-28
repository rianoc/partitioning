# Partitioning data in kdb+

Kdb+ supports partitioned databases. This means that when data is stored to disk it is [partitioned](https://code.kx.com/q4m3/14_Introduction_to_Kdb+/#143-partitioned-tables) in to different folders.

    /HDB
        sym
        …
        /2020.06.25
            /trade
            /quote
        /2020.06.26
            /trade
            /quote
        …

Each day when data is stored a new date folder will be created.
Once the data is loaded in to a process a virtual `date` column will be created.
This allows the user to include a date filter in their where clause:

```q
select from quote where date=2020.06.25,sym=`FDP
```

This physical partitioning and seamless filtering allows kdb+ to perform very performant queries as a full database scan is not required to retrieve data.

Furthermore native [map-reduce](https://code.kx.com/q/wp/multi-thread/#map-reduce-with-multi-threading) allow queries which span multiple partitions to make use of [multi-threading](https://code.kx.com/q/wp/multi-thread/#map-reduce-with-multi-threading) for further speedup:

```q
select vwap: size wavg price by sym from trade where date within 2020.06.01 2020.06.26
```

Aside from `date` the other possible choices for the [parted domain](https://code.kx.com/q4m3/14_Introduction_to_Kdb+/#1432-partition-domain) are: `year`, `month`, and `int`.

In the rest of this post we will explore some uses of `int` partitioning.

*Note: This post serves as a discussion on a topic - it is not intended as deployable code in mission critical systems*

## Hourly Partitioning

Hourly Partitioning can be used as a way to reduce the RAM footprint of a kdb+ system. This solution is very simple to implement but not as as powerful as a fully thought out [intraday-writedown](https://code.kx.com/q/wp/intraday-writedown) solution.

Firstly a helper function is needed to convert timestamps to an int equivalent:

```q
hour:{`int$sum 24 1*`date`hh$\:x}
```

This `hour` function takes a timestamp calculates the number of hours since the kdb+ epoch:

```q
q)hour 2000.01.01D01
1i
q)hour 2020.06.27D16
179608i
```

Taking [kdb-tick](https://github.com/KxSystems/kdb-tick) as a template very few changes are needed to explore hourly partitioning.

1. Edits in `tick.q` are mainly focused around using `hour .z.P` rather than `.z.D` along with some renaming of variables for clarity replacing day with hour.
2. Changes were also needed in `tick.q` and `r.q` related to the naming of the tickerplant log file, while all dates are 10 characters long the int hour value will eventually grow in digits.

    At 4pm on Saturday January 29th 2114 to be exact!

    ```
    q)hour 2114.01.29D16
    1000000i
    ```

3. Moving the `time` column from a timestamp (`n`) to a timestamp (`p`) was chosen. This [datatype](https://code.kx.com/q/basics/datatypes/) does not use more space or loose any precision but has the benefit of including the date which is helpful to allow viewing of the date now that the `date` column is removed. Another option is a helper function to extract the date back from the encoded `int` column:

    ```q
    q)intToDate:{`date$x div 24}
    q)hour 2020.06.27D16
    179608i
    q)intToDate 179608i
    2020.06.27
    ```

The full extent of the changes are best explored by reviewing the [git commit](https://github.com/rianoc/partitioning/commit/ab0e32942a75a15df5b8e4d43b285dafe46031ce).

Once the HDB process reloads after an hour threshold has been crossed you can explore the data. On disk the `int` partition folders can be seen:

    /HDB
        sym
        …
        /179608
            /trade
            /quote
        /179609
            /trade
            /quote
        …

 When querying the HDB the virtual `int` column is visible:

```q
q)quote
int    sym time                          bid       ask        bsize asize
-------------------------------------------------------------------------
179608 baf 2020.06.27D16:20:46.040466000 0.3867353 0.3869818  5     7
179608 baf 2020.06.27D16:20:46.040466000 0.726781  0.6324114  2     8
```

The same `hour` function can be used to query the data efficiently:

```q
select from trade where int=hour 2020.06.27D16
select from trade where int within hour 2020.06.26D0 2020.06.27D16
```

## Fixed size partitioning

One possible concern with hourly partitioning would be the fact that data does not always stream at a steady rate. This would lead to partitions of varying sizes and would not protect a system well if there was a sudden surge in volume of incoming data.

To create a system with a more strictly controlled upper limit on memory usage we will build an example which will flush data to disk based on a triggered condition on the size of the tickerplant log. This will be used as a proxy for how much RAM the RDB is likely to be using. This trigger could easily be reconfigured to fire based on total system memory usage or any other chosen value.
For this example implementation the size of the tickerplant log file is used to control when to flush data.

A new command line value is passed which is accessed with [.z.x](https://code.kx.com/q/ref/dotz/#zx-argv) and multiplied by the number of bytes in a megabyte:

```q
\d .u
n:("J"$.z.x 2)*`long$1024 xexp 2;
```

This new `n` variable is compared to the size of the log file as given by [hcount](https://code.kx.com/q/ref/hcount/) after each time data is appended. If the threshold is breached then the `endofpart` call is triggered:

```q
if[n<=hcount L;endofpart[]]
```

**Note: While this method is very exact it would not be recommended in a tickerplant receiving many messages as the overhead of polling the filesystem for the file size can be a slow operation.**

The int value now starts from `0` and increments each time a partition is added:

```q
q)select from quote
int sym time                          bid       ask        bsize asize
----------------------------------------------------------------------
0   baf 2020.06.28D17:15:54.751561000 0.3867353 0.3869818  5     7
0   baf 2020.06.28D17:15:54.751561000 0.726781  0.6324114  2     8
```

On startup the tickerplant must list all files using [key](https://code.kx.com/q/ref/key/#files-in-a-folder) and determine the maximum partition value to use:

```q
p:{f:x where x like (get `..src),"_*";$[count f;max "J"$.[;((::);1)]"_" vs'string f;0]}key `:.;
```

Now that our partitions are no longer tied to a strict time domain the previous solution of a smaller helper function is not sufficient to enable efficient querying. A lookup table will be needed to enable smart lookups across the partitions.

```q
q)lookup
part tab   minTS                         maxTS
----------------------------------------------------------------------
0    quote 2020.06.28D17:14:33.520763000 2020.06.28D17:15:54.751561000
0    trade 2020.06.28D17:14:33.515537000 2020.06.28D17:15:54.748619000
1    quote 2020.06.28D17:15:54.762522000 2020.06.28D17:16:57.867296000
1    trade 2020.06.28D17:15:54.757298000 2020.06.28D17:16:57.864316000
```

This table sits in the root of the HDB. Each time a partition is written the lookup table has new information appended to it by `.u.addLookup`:

```q
.u.addLookup:{`:lookup/ upsert .Q.en[`:.] raze {select part:enlist x,tab:enlist y,minTS:min time,maxTS:max time from y}[x] each tables[]};
```

`saveAndReload` replaces `.Q.hdpf` as now when the HDB is reloading `cacheLookup` needs to be called:

```q
k)saveAndReload:{[h;d;p;f](@[`.;;0#].Q.dpft[d;p;f]@)'t@>(#.:)'t:.q.tables`.;if[h:@[hopen;h;0];h"system\"l .\";cacheLookup[]";>h]};
```

`cacheLookup` reads from the `lookup` from disk and creates an optimised dictionary `intLookup` which will be used when querying data:

```q
cacheLookup:{
 if[`lookup in tables[];
 intLookup::.Q.pt!{`lim xasc ungroup select (count[i]*2)#part,lim:{x,y}[minTS;maxTS] from lookup where tab=x} each .Q.pt];
 };
 ```

A new helper function `findInts` in how users will perform efficient queries on this database:

```q
findInts:{[t;s;e] exec distinct part from intLookup[t] where lim within (s;e)}
```

```
q)select from quote where int in findInts[`quote;2020.06.28D17:15:54.75;2020.06.28D17:15:54.77],time within 2020.06.28D17:15:54.75 2020.06.28D17:15:54.77
int sym time                          bid       ask        bsize asize
----------------------------------------------------------------------
0   baf 2020.06.28D17:15:54.751561000 0.3867353 0.3869818  5     7
0   baf 2020.06.28D17:15:54.751561000 0.726781  0.6324114  2     8
1   baf 2020.06.28D17:15:54.762522000 0.3867353 0.3869818  5     7
1   baf 2020.06.28D17:15:54.762522000 0.726781  0.6324114  2     8
1   igf 2020.06.28D17:15:54.762522000 0.9877844 0.7750292  9     4
```

The full extent of the changes are best explored by reviewing the [git commit](https://github.com/rianoc/partitioning/commit/abba35c3dc1806181c03dd084cc8a5059d2c242a).

## Possible extensions

### Filter time buffer

The `hour` helper is exact, this may be to exact for some use cases. For example a table with multiple timestamps which are created as the data flows through various processes. This timestamps will be slightly behind the final timestamp created in the tickerplant.

**Note: This issue is not limited to `int` partitioning and can be beneficial in any partitioned database.**

If a user queries without accounting for this they could be presented with incomplete results:

```q
select from trade where int within hour 2020.06.26D0 2020.06.26D07, otherTimeCol=2020.06.26D0 2020.06.26D07
```

This can be manually accounted for by adding a buffer to the end value of your time window. Here one second is used:

```q
select from trade where int within hour 0D 0D00:01+2020.06.26D0 2020.06.26D07, otherTimeCol=2020.06.26D0 2020.06.26D07
```

Better still would be wrap this in a small utility for ease of use:

```q
buffInts:{hour 0D 0D00:01+x}
select from trade where int within buffInts 2020.06.26D0 2020.06.26D07, otherTimeCol=2020.06.26D0 2020.06.26D07
```

### Extended lookup table

Choosing a buffer value is an inexact science. A more efficient solution is to use a `lookup` table, this will allow for fast queries in both the hourly and fixed size partition examples. The table can be extended to include any extra columns as needed:

```q
q)lookup
part tab minTS maxTS minOtherCol maxOtherCol
--------------------------------------------
```

The user would then pass in an extra parameter to `findInts` to specify which column to use when choosing int partitions:

```q
findInts[`quote;`otherCol;2020.06.28D16;2020.06.28D17]
```

These lookup tables are very powerful. Not only in these cases where data is slightly delayed but in fact any delay can how be handled gracefully, even if data is months late the lookup table protects against expensive full database scans or users missing data by making their queries to restrictive in their lookup of partitions assuming a certain maximum 'lateness' of data.
