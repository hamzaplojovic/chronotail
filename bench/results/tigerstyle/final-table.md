| Workload | Old CT | Tiger CT | NanoTS | SQLite | vs NanoTS | vs SQLite |
|---|---:|---:|---:|---:|---:|---:|
| append-8-series | 15.91M | 14.37M | 6.65M | 716.35k | 2.16× | 20.06× |
| append-A-none | 26.83M | 13.45M | 2.83M | 755.63k | 4.76× | 17.80× |
| append-B-10MiB | 23.98M | 14.08M | 2.33M | 769.89k | 6.05× | 18.29× |
| append-C-1MiB | 24.64M | 13.75M | 2.18M | 763.46k | 6.32× | 18.01× |
| concurrent-1-readers | 2.32M | 1.72M | 36.01k | 48.27k | 47.84× | 35.69× |
| concurrent-1-writer | 14.68M | 7.31M | 1.99M | 737.32k | 3.67× | 9.91× |
| concurrent-32-readers | 8.61M | 8.34M | 43.94k | 223.62k | 189.85× | 37.31× |
| concurrent-32-writer | 7.90M | 1.33M | 2.47M | 145.69k | 0.54× | 9.13× |
| concurrent-8-readers | 8.39M | 6.62M | 42.61k | 154.08k | 155.34× | 42.96× |
| concurrent-8-writer | 8.23M | 3.92M | 2.41M | 294.44k | 1.63× | 13.32× |
| point-lookup-warm | 2.68M | 1.88M | 880.41k | 210.09k | 2.14× | 8.96× |
| range-100-compressed-warm | 329.07k | 166.21k | — | — | — | — |
| range-100-raw-warm | 1.74M | 1.23M | 52.70k | 44.74k | 23.32× | 27.47× |
| storage-random-compressed | 22.29M | 11.57M | — | — | — | — |
| storage-random-raw | 28.67M | 15.50M | — | — | — | — |
| storage-smooth-compressed | 22.45M | 12.52M | — | — | — | — |
| storage-smooth-raw | 27.59M | 15.33M | — | — | — | — |
