# Partitioning data in kdb+

- [Partitioning data in kdb+](#partitioning-data-in-kdb)
  - [Hourly partitioning](#hourly-partitioning)
  - [Fixed size partitioning](#fixed-size-partitioning)
    - [Alternate methods to control when to partition](#alternate-methods-to-control-when-to-partition)
  - [Handling late data](#handling-late-data)
    - [Filter time buffer](#filter-time-buffer)
    - [Extended lookup table](#extended-lookup-table)
  - [Reducing number of files](#reducing-number-of-files)
    - [Reducing hourly partitions](#reducing-hourly-partitions)
    - [Reducing fixed partitions](#reducing-fixed-partitions)

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
select vwap: size wavg price by sym from trade
 where date within 2020.06.01 2020.06.26
```

Aside from `date` the other possible choices for the [parted domain](https://code.kx.com/q4m3/14_Introduction_to_Kdb+/#1432-partition-domain) are: `year`, `month`, and `int`.

In the rest of this post we will explore some uses of `int` partitioning.

**Note: This post serves as a discussion on a topic - it is not intended as deployable code in mission critical systems**

## Hourly partitioning

Hourly Partitioning can be used as a way to reduce the RAM footprint of a kdb+ system. This solution is very simple to implement but not as as powerful as a fully thought out [intraday-writedown](https://code.kx.com/q/wp/intraday-writedown) solution.

Firstly a helper function is needed to convert timestamps to an int equivalent:

```q
hour:{`int$sum 24 1*`date`hh$\:x}
```

This `hour` function takes a timestamp and calculates the number of hours since the kdb+ epoch:

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

3. Moving the `time` column from a timestamp (`n`) to a timestamp (`p`) was chosen. This [datatype](https://code.kx.com/q/basics/datatypes/) does not use more space or lose any precision but has the benefit of including the date which is helpful to allow viewing of the date now that the `date` column is removed. Another option is a helper function to extract the date back from the encoded `int` column:

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

If you wish to store data prior to the kdb+ epoch `2000.01.01D0` you will need to make some adjustments. This is due to a requirement for the int partitions to have positive values.

To use a different epoch only small changes are needed. Here `1970.01.01`:

```q
hour:{`int$sum 24 1*@[;0;-;1970.01.01] `date`hh$\:x}
intToDate:{1970.01.01+x div 24}
```

```q
q)hour 2020.06.27D16
442576i
q)intToDate 442576i
2020.06.27
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
p:{
 f:x where x like (get `..src),"_*";
 $[count f;max "J"$.[;((::);1)]"_" vs'string f;0]
 } key `:.
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
.u.addLookup:{
 `:lookup/ upsert .Q.en[`:.] raze {select part:enlist x,tab:enlist y,
  minTS:min time,maxTS:max time from y}[x] each tables[]
 };
```

`saveAndReload` replaces [.Q.hdpf](https://code.kx.com/q/ref/dotq/#qhdpf-save-tables) as now when the HDB is reloading `cacheLookup` needs to be called:

```q
k)saveAndReload:{[h;d;p;f]
 (@[`.;;0#].Q.dpft[d;p;f]@)'t@>(#.:)'t:.q.tables`.;
 if[h:@[hopen;h;0];
   h"system\"l .\";cacheLookup[]";>h]
 };
```

`cacheLookup` reads from the `lookup` from disk and creates an optimised dictionary `intLookup` which will be used when querying data:

```q
cacheLookup:{
 if[`lookup in tables[];
 intLookup::.Q.pt!{
    `lim xasc ungroup select (count[i]*2)#part,lim:{x,y
    }[minTS;maxTS] from lookup where tab=x
  } each .Q.pt];
 };
 ```

A new helper function `findInts` is how users will perform efficient queries on this database:

```q
findInts:{[t;s;e] exec distinct part from intLookup[t] where lim within (s;e)}
```

```
q)select from quote where 
 int in findInts[`quote;2020.06.28D17:15:54.75;2020.06.28D17:15:54.77], 
 time within 2020.06.28D17:15:54.75 2020.06.28D17:15:54.77
int sym time                          bid       ask        bsize asize
----------------------------------------------------------------------
0   baf 2020.06.28D17:15:54.751561000 0.3867353 0.3869818  5     7
0   baf 2020.06.28D17:15:54.751561000 0.726781  0.6324114  2     8
1   baf 2020.06.28D17:15:54.762522000 0.3867353 0.3869818  5     7
1   baf 2020.06.28D17:15:54.762522000 0.726781  0.6324114  2     8
1   igf 2020.06.28D17:15:54.762522000 0.9877844 0.7750292  9     4
```

The full extent of the changes are best explored by reviewing the [git commit](https://github.com/rianoc/partitioning/commit/abba35c3dc1806181c03dd084cc8a5059d2c242a).

### Alternate methods to control when to partition

Rather than polling the file system to use as a metric to trigger the creation of a new partition other methods could be chosen. Methods can be basic, needing some human tuning of limits to be useful, or exact (even for dynamic incoming data) but possibly computationally expensive.

One choice would be a basic count of cumulative rows across all incoming table data and trigger at a pre-set limit. However, the resulting size of data could vary wildly depending on the number of columns in the tables.

For a slightly more dynamic/accurate method one could could use a lookup dictionary of the size in bytes of each [datatype](https://code.kx.com/q/basics/datatypes/):

```q
typeSizes:(`short$neg (1+til 19) except 3)!1 16 1 2 4 8 4 8 1 8 8 4 4 8 8 4 4 4
calcSize:{sum count[x]*typeSizes type each value first x}
```

To test we replay a 5121KB tickerplant transaction log using [-11!](https://code.kx.com/q/basics/internal/#-11-streaming-execute):

```q
q)quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$();bsize:`int$();asize:`int$())
q)trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`int$())
q)upd:insert
q)-11!`sym_0
12664
q)div[;1024] sum calcSize each (trade;quote)
q)4204
```

The resulting estimate is 4204KB. Comparing this to the size of the same data as stored on disk (uncompressed) results in a similar 4244KB:

```bash
$du -s HDB/0
4244    HDB/0
```

The main flaw with the `calcSize` function is it's inability to calculate the size of data in array columns, such as the string type. It could be extended to account for this but then it's complexity and run time would increase as it would need to integrate each cell rather than using only the first row as it does in it's basic form.

Kdb+ itself provides a shortcut to calculate the IPC serialised size of an object with [-22!](https://code.kx.com/q/basics/internal/#-22x-uncompressed-length):

```q
q)div[;1024] sum -22!/:(trade;quote)
3710
```

While optimised for speed `-22!` remains an expensive operation. It also gives inaccurate results for symbol type data as in memory they are interned for efficiency but during IPC transfer use varying space depending on their length.

In common with  `calcSize` both these methods also suffer from being unable to account for the memory overheads associated with any columns which have [attributes](https://code.kx.com/q/ref/set-attribute/) applied to them.

In the process itself [.Q.w](https://code.kx.com/q/ref/dotq/#qw-memory-stats) can be interrogated to view actual memory reserved in the heap and used by objects:

```
q)div[;1024] .Q.w[]`heap`used
65536 4702
```

Whilst `.Q.w` in the RDB may seem like a good way to trigger in practice having the tickerplant poll another process is not a good idea as it is designed to be a self contained process which will reliably store the transaction log and never be able to be blocked a downstream process, it publishes data asynchronously for this reason.

Overall this is an area where the ["keep it simple, stupid"](https://en.wikipedia.org/wiki/KISS_principle) principle applies. There is little benefit to attempting to be too exact. Choosing a simple method and allowing a cautious RAM overhead for any inaccuracy is the best path to follow.

## Handling late data

### Filter time buffer

The `hour` helper is exact, this may be to exact for some use cases. For example a table with multiple timestamp columns which are created as the data flows through various processes. These other timestamp columns will be slightly behind the final timestamp created in the tickerplant.

**Note: This issue is not limited to `int` partitioning and can be beneficial in any partitioned database.**

If a user queries without accounting for this they could be presented with incomplete results:

```q
select from trade where 
 int within hour 2020.06.26D0 2020.06.26D07, 
 otherTimeCol within 2020.06.26D0 2020.06.26D07
```

This can be manually accounted for by adding a buffer to the end value of your time window. Here one second is used:

```q
select from trade where 
 int within hour 0D 0D00:01+2020.06.26D0 2020.06.26D07,
 otherTimeCol within 2020.06.26D0 2020.06.26D07
```

Better still would be wrap this in a small utility for ease of use:

```q
buffInts:{hour 0D 0D00:01+x}
select from trade where int within buffInts 2020.06.26D0 2020.06.26D07,
 otherTimeCol=2020.06.26D0 2020.06.26D07
```

### Extended lookup table

Choosing a buffer value is an inexact science. A more efficient solution is to use a `lookup` table, this will allow for fast queries in both the hourly and fixed size partition examples. The table can be extended to include any extra columns as needed. `.u.addLookup` is edited to gather stats on the extra columns as needed:

```q
.u.addLookup:{
 `:lookup/ upsert .Q.en[`:.] raze {select part:enlist x,tab:enlist y,
  minTS:min time,maxTS:max time,
  minOtherCol:min otherCol,maxOtherCol:max otherCol,
   from y}[x] each tables[]
 };
```

```q
q)lookup
part tab minTS maxTS minOtherCol maxOtherCol
--------------------------------------------
```

`cacheLookup` behaviour and the `intLookup` it creates are now also changed:

```q
cacheLookup:{
 if[`lookup in tables[];
 intLookup::`lim xasc ungroup select column:`time`time`otherCol`otherCol,
             lim:(minTS,maxTS,minOtherCol,maxOtherCol) by part,tab from lookup;
 };
 ```

 ```q
 findInts:{[t;c;s;e]
  exec distinct part from intLookup where tab=t,column=c,lim within (s;e)
 }
 ```

The user would then pass in an extra parameter to `findInts` to specify which column to use when choosing int partitions:

```q
findInts[`quote;`otherCol;2020.06.28D16;2020.06.28D17]
```

These lookup tables are very powerful. Not only in these cases where data is slightly delayed but in fact any delay can how be handled gracefully, even if data is months late the lookup table protects against expensive full database scans or users missing data by making their queries too restrictive in their lookup of partitions assuming a certain maximum 'lateness' of data.

## Reducing number of files

One side effect of int partitioning is a larger numbers of files being created on disk. At query time this can result in slower response time if many partitions need to be opened and scanned. Errors can also occur if the process [ulimit](https://code.kx.com/q/kb/linux-production/#compression) is breached. At an extreme the file system may run out of [inode](https://en.wikipedia.org/wiki/Inode) allocation space. Choosing how often a partition is created is one way to prevent too many files. Another is to implement a `defrag` process which will join several partitions together.

This process is started and passed the ports for the RDB and HDB:

```bash
q defrag.q -s 4 ::5011 ::5012
```

`-s 4` is passed to create [secondary threads](https://code.kx.com/q/basics/cmdline/#-s-secondary-threads) so multiple cores are used to speed up the task.

The `defrag` function is then available which takes the following parameters:

* `hdb` - hsym to root of HDB
* `src` - int list of partitions to combine
* `dst` - int destination partition
* `comp` - [compression](https://code.kx.com/q/basics/internal/#-19-compress-file) settings
* `p` - symbol column name to apply [parted attribute](https://code.kx.com/q/basics/internal/#-19-compress-file) on
* `typ` - symbol `hourly` or `fixed` to specify the type of HDB

It's source is viewable in [defrag.q](https://github.com/rianoc/partitioning/blob/master/defrag.q)

### Reducing hourly partitions

```q
defrag[`:hourly/HDB;179608 179609;179608;17 2 6;`sym;`hourly]
```

For data to remain queryable in a performant manner there are some requirements:

* Partitions being joined must be contiguous
* The destination must be the minimum partition of the source list

These requirements are related to how the previously used `hour` function will be replaced. Now that the partitions are combined it will not function correctly:

```q
q)select from trade where int in hour 2020.06.27D17, 
   time within 2020.06.27D17 2020.06.27D18
int sym time price size
-----------------------
```

This is due to the function expecting the data to be in partition `179609` which no longer exists as it has been merged in to `179608`.

To solve this we can make use of the [bin](https://code.kx.com/q/ref/bin/) function. It returns the prevailing bucket a value falls in to:

```q
q)list:0 2 4
q)list bin 0 1 3 5
0 0 1 2
q)list list bin 0 1 3 5
0 0 2 4
```

When kdb+ loads a partitioned database it creates a global variable which contains the list of all partitions. For date partitioned it is name `date` and for int `int` etc. This list can then be used to extend our `hour` function with `bin` to find the correct bucket:

```q
q)hour:{int int bin `int$sum 24 1*`date`hh$\:x}
```

Our combined hours now correctly return that they both reside within a single partition:

```q
q)hour 2020.06.27D16
179608
q)hour 2020.06.27D17
179608
```

The previously failing query now succeeds:

```q
q)select from trade where int in hour 2020.06.27D17, 
   time within 2020.06.27D17 2020.06.27D18
int    sym time                          price    size
------------------------------------------------------
179608 baf 2020.06.27D17:00:00.000000000 0.949975 1   
179608 baf 2020.06.27D17:00:00.050000000 0.391543 2  
```

### Reducing fixed partitions

```q
defrag[`:fixed/HDB;0 1 2 3 4;0;17 2 6;`sym;`fixed]
```

The requirements about how partitions are combined which applied to hourly database do not apply to the fixed database. This is because the `lookup` table exists.

After running `defrag` no changes are needed in the helper function `findInts`. Instead during `defrag` the lookup table is updated with the latest information regarding partitions. To ensure two processes do not try to write to `lookup` simultaneously the RDB is contacted to perform this step.

The logic for this is best explored by viewing the [reloadFixed](https://github.com/rianoc/partitioning/blob/1c34431fed9fdc5cff9b4fe3b63fc5a9b5b57621/defrag.q#L32) function defined in `defrag.q`.
