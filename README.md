# Partitioning data in kdb+

Kdb+ supports partitioned databases. This means that when data is stored to disk it partitioned in to different folders.

    /db
        [sym]
        …
        /2020.06.25
            /trade
            /quote
        /2020.06.26
            /trade
            /quote
        …

Each day when data is stored a new date folder will be created.

One the data is loaded in to a process a virtual `date` column will be created.
This allows the user to include a date filter in their where clause.

```q
select from quote where date=2020.06.25,sym=`FDP
```

This physical partitioning and seamless filtering allows kdb+ to perform very performant queries as a full database scan is not required to retrieve data.

Furthermore native [map-reduce](https://code.kx.com/q/wp/multi-thread/#map-reduce-with-multi-threading) allow queries which span multiple partitions to make use of [multi-threading](https://code.kx.com/q/wp/multi-thread/#map-reduce-with-multi-threading) for further speedup.

```q
select vwap: size wavg price by sym from trade where date within 2020.06.01 2020.06.26
```

Aside from `date` the other possible choices for the [parted domain](https://code.kx.com/q4m3/14_Introduction_to_Kdb+/#1432-partition-domain) are: `year`, `month`, and `int`.

In the rest of this post we will explore some uses of `int` partitioning.

## Hourly Partitioning

Taking [kdb-tick](https://github.com/KxSystems/kdb-tick) as a template very few changes are needed to explore hourly partitioning.

## Fixed size partitioning
