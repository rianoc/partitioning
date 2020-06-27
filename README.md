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

The full extent of the changes are best explored by reviewing the [git commit](https://github.com/rianoc/partitioning/commit/ab0e32942a75a15df5b8e4d43b285dafe46031ce) of the changes being made.

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

The code is best explored by reviewing the [git commit](https://github.com/rianoc/partitioning/) of the changes made.

The key logic is the trigger which checks the size of the TP log file. The example value is set to `5MB`:

```q
//ToDo: show logic which checks TP log size
```

The int value now starts from `0` and increments each time a partition is added:

```q
q)select from trade
int    sym time                 price      size
-----------------------------------------------
0 fgl 0D07:43:50.772510000 0.08123546 7
0 fgl 0D07:43:51.785912000 0.08123546 7
```

Now that our partitions are no longer tied to a strict time domain the previous solution of a smaller helper function is not sufficient to enable efficient querying. A lookup table will be needed to enable smart lookups across the partitions.

```q
q)lookup
part tab minTS maxTS
--------------------
//Todo: Add sample rows here
```

This table sits in the root of the HDB. Each time a partition is written the lookup table has new information appended to it.

```q
//ToDo: show change in .u.end which appends to lookup
```

During reload the latest version of lookup is brought in to memory and keyed. This the speed of lookups and also prevents users querying it while it is being appended to on disk.

At query time a new helper function `findInts` can be used

```q
//ToDo: Show definition of findInts and examples of it being used
```

## Possible extensions

The `hour` helper is exact, this may be to exact for some use cases. For example a table with multiple timestamps which are created as the data flows through various processes. This timestamps will be slightly behind the final timestamp created in the tickerplant.

If a user queries without accounting for this they could be presented with incomplete results:

```q
select from trade where int within hour 2020.06.26D0 2020.06.26D07, otherTimeCol=2020.06.26D0 2020.06.26D07
```

This can be manually accounted for:

```q
select from trade where int within hour 0D 0D00:01+2020.06.26D0 2020.06.26D07, otherTimeCol=2020.06.26D0 2020.06.26D07
```

Better still would be wrap this in a small utility for ease of use:

```q
buffInts:{hour 0D 0D00:01+x}
select from trade where int within buffInts 2020.06.26D0 2020.06.26D07, otherTimeCol=2020.06.26D0 2020.06.26D07
```

We could apply a similar buffered lookup in the fixed partition use case. However an even more powerful solution would be to extend the lookup table to store exact information for as many columns as we wish:

```q
q)lookup
part tab minTS maxTS minOtherCol maxOtherCol
--------------------------------------------
//Todo: Add sample rows here
```
