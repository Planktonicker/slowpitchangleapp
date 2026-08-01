# clips/ — test footage drop folder

AirDrop your slo-mo clips from the iPhone into this folder, then rename them
by setting so `batch_run.py` can build the go/no-go scoreboard:

| Prefix     | Meaning                                                        |
|------------|----------------------------------------------------------------|
| `tee_`     | outdoor tee swings                                             |
| `teeid_`   | the 5 identical-intent tee swings (repeatability set, G4)      |
| `toss_`    | outdoor soft toss                                              |
| `live_`    | field, live pitching                                           |
| `cage_`    | batting cage, camera INSIDE the cage                           |
| `net_`     | cage, filmed through the net (expected-failure comparison)     |
| `fly_`     | fly balls with paced-off landing distance (G3)                 |

Example: `tee_01.mov`, `teeid_03.mov`, `fly_02.mov`.

Video files are gitignored — footage never gets committed. Keep the paper log
next to your clips (see docs/CAPTURE_PROTOCOL.md).
