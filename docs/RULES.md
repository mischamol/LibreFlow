# Rules and sources

Every number LibreFlow shows in the **Analysis** advice and the **Running Plan** comes from fixed, transparent rules
that run on your own device – no AI, no cloud. This page lists all of them: what is measured, which limit is used,
why, and which research it is based on. Every rule has a source; where the exact number is LibreFlow's own choice
rather than a number from that source, it also says **rule of thumb**.

The source numbers **[1]–[29]** are the same as in the app (the *Sources* lists under the advice and the plan).
The rules are a guide, not medical advice: listen to your body, and see a doctor with pain or illness.

The rules live in one file, [`web/libreflow.html`](../web/libreflow.html) (the app uses a copy of it).

**Contents**
1. [Basic measures](#1-basic-measures) – heart rate, zones, training load, fitness (VDOT), efficiency
2. [Shared training signals](#2-shared-training-signals) – what the advice and the plan both use
3. [Analysis advice](#3-analysis-advice)
4. [Running plan](#4-running-plan)
5. [Rules of thumb](#5-rules-of-thumb)
6. [Sources](#6-sources)

---

## 1. Basic measures

### Heart-rate settings
| Setting | Where it comes from | Default when unknown |
|---|---|---|
| Max heart rate | Your Polar profile (export), or what you enter | 98th percentile of the max heart rate of your activities in the last 3 years, else 190 |
| Resting heart rate | Polar profile or entered | 55 bpm |
| Aerobic threshold (AeT) | Polar profile or entered | 80% of max heart rate |
| Anaerobic threshold (AnT) | Polar profile or entered | 88% of max heart rate |

### Intensity: three zones
For the intensity advice, time is split into **easy** (below AeT), **moderate** (AeT up to AnT) and **hard** (from
AnT). From the second-by-second heart rate when available, else the whole activity at its average heart rate. This
is the three-zone model used in research on how endurance athletes distribute their training [2, 3].

### Training zones (five heart-rate, five pace)
Used by the running plan for each session, and can be sent to the watch. Automatic unless you set them yourself.
- **Heart rate**: zone limits ½ max, AeT − 10, AeT, halfway AeT–AnT, AnT, max.
- **Pace**: limits halfway between Daniels' training paces [1], so each pace sits in the middle of its zone:
  1 recovery, 2 easy (E), 3 marathon (M), 4 threshold (T), 5 interval (I). Based on your current VDOT (below).

### Training load (TRIMP)
Banister's training impulse [17]: for each minute, a weight that rises exponentially with heart-rate reserve
(`x = (HR − rest) / (max − rest)`, weight `x · 0.64 · e^(k·x)`, k = 1.92 for men, 1.67 for women), summed over
the activity. From the per-second heart rate when available, else from the average. All sports count.

### Fitness, fatigue and form
The Banister impulse–response model [17]: **fitness** = 42-day exponential average of daily TRIMP, **fatigue** =
7-day average, **form** = fitness − fatigue. The model describes trends well, but its predictions for one athlete
are uncertain [18]; the 42/7-day time constants are the usual ones from cycling software (Allen & Coggan's
performance manager [25]), and the limits used on form (below) are a rule of thumb.

### Fitness estimate (VDOT) and predictions
Daniels' VDOT [1] (Daniels & Gilbert's oxygen-cost and time-to-exhaustion formulas): from whole runs of at least
3 km lasting 12 minutes to 5 hours, and from the best 5 km and 10 km within runs. **Current VDOT** = the best of the
last 120 days. Race predictions are the times that give the same VDOT; training paces are fixed fractions of it
(easy 62–70%, marathon 80%, threshold 88%, interval 97.5% of VDOT). Predictions beyond the marathon are not made.

### Efficiency (metres per heartbeat)
Speed divided by heart rate, for runs of at least 3 km (or from the per-second data). A rising value at the same
effort means a better aerobic fitness; a sudden drop points to fatigue, heat or illness [12].

### Aerobic decoupling
For activities of 40 minutes or more: how much efficiency drops from the first to the second half, leaving out the
first 10 minutes. Below 5% is the usual target for long easy runs, a coaching guideline from Joe Friel [23]; in
82,303 marathon runners, less and later decoupling went with faster finishing times [24].

### Other figures
- **Best efforts and records**: the fastest 1 km, 5 km, 10 km and half marathon anywhere within a run, from the
  per-second distance.
- **Polar running index**: computed by the watch itself, shown as reported.
- Pace-based parts (pace, efficiency, VDOT, predictions, best efforts, cadence) only use running activities.

---

## 2. Shared training signals

The Analysis advice and the Running Plan use **the same function** for these signals, computed at the same
moment (the end of today; Analysis uses its last activity day when your data is more than 28 days old). So they
always reach the same conclusion. Distances count **running only**; other sports count through fitness and fatigue.

| Signal | Definition |
|---|---|
| Acute load | km in the last 7 days |
| Chronic load | average km per week over the last 4 weeks |
| Block | the best 8-week average km per week of the last 2 years (calendar weeks) |
| Experienced | at least 12 of the last 24 months with 4 or more activities |
| Load ratio | acute ÷ the higher of the chronic load and – for experienced runners – the block |
| Break | longest gap between activities in the last 7 weeks |
| Efficiency drop | metres per heartbeat of the last 2 weeks more than 5% below the 8 weeks before (at least 2 runs) |
| Form | fitness/fatigue/form from the model above (when fitness > 5) |

Why the block: for someone with a training history, a week back at a volume they sustained before is not a
dangerous spike, even when a break pulled the 4-week average down. Week-to-week changes in distance were not linked
to injuries in a cohort of 5,200 runners [6], and the acute:chronic ratio is a rough guide at best [10].

---

## 3. Analysis advice

Each advice item in the app shows *Based on: [n]*, with a note when the exact limit is a rule of thumb. The most urgent comes first.

| Advice | Rule | Sources |
|---|---|---|
| **Back to your usual volume** | Load ratio vs. block ≤ 1.3 while the plain ratio vs. the 4-week average is above 1.3 (experienced runners) | [6], [10] |
| **Load rising too fast** | Load ratio > 1.5 | [9], [10] |
| **Solid build-up** | Load ratio 1.3–1.5 | [9], [10] |
| **Easy week** | Load ratio < 0.7 (with more than 5 km/week) | [9], [10] |
| **Load in balance** | Load ratio 0.7–1.3 | [9], [10] |
| **Big jump in weekly volume** | Last full week more than 25% above the 4 weeks before (or above the block for experienced runners) | [7], [8], [6] |
| **Long run relatively heavy** | Longest run of 4 weeks > 12 km and more than 40% of the usual week (for experienced runners the usual week is at most the block, at most 2× the 4-week average). Daniels advises 25–30%; 40% is a rule of thumb | [1], [6] |
| **Few truly easy sessions** / **Good intensity distribution** / **Intensity** | Easy share of running time in 8 weeks below 65% / at least 75% / in between (with more than 3 hours of data) | [2], [3], [4] |
| **Aerobic fitness rising / stable** / **Efficiency dropping** | Metres per heartbeat of the last 8 weeks vs. the 6 months before: > +3% / in between / < −4% | [12] |
| **Fatigue signal** | Efficiency drop (section 2) | [12] |
| **Break** | A gap of more than 10 days in the last 12 weeks: resume at ~70% of the previous volume | [15], [14] |
| **A lot of fatigue built up** | Form below −40% of fitness | [17], [18], [25] |
| **Fatigue after your break** | Form below −40% of fitness after a gap of 10+ days in the last 7 weeks: in the model fitness drops during a break, so a normal week afterwards reads as high fatigue | [17], [18], [25] |
| **You are building up** | Form between −40% and −20% of fitness | [17], [18], [25] |
| **Rested** | Form above +25% of fitness | [17], [18], [25] |
| **Load and recovery in balance** | Form between −20% and +25% | [17], [18], [25] |
| **No rest day** | 10 or more days in a row with activity. The consensus advises a passive rest day every week; warning only after 10 days is a rule of thumb | [21] |
| **Frequency** | Fewer than 2.5 activities a week over 12 weeks. Guidelines advise aerobic exercise on 3–5 days a week; 2.5 is a rule of thumb | [22] |
| **Strong aerobic base** / **Heart rate drifts up** / **Aerobic decoupling** | Median decoupling of runs ≥ 60 min in 12 weeks: ≤ 5% / > 8% / in between. 5% is a coaching guideline, 8% a rule of thumb | [23], [24] |
| **Cadence** | Median below 160 steps/min: a 5% higher step rate reduced knee loading, 10% also hip loading | [19] |
| **Polar running index** | Median of 8 weeks vs. a year ago | – (Polar's own figure) |
| **Your seasonal pattern** | Months with the most and least distance, from 3 or more years of your own activities | – (your own data) |
| **Shoes** | A pair past its reminder distance (default 400 km). Cushioning drops with distance (below 60% of new after 250–500 miles in a machine test); a link with injuries is not proven, so 400 km is a rule of thumb | [26] |
| **Running goal** | Shown when the running plan is not feasible or has caveats (section 4) | as in the plan |

The form limits (−20% / −40% / +25% of fitness) are a rule of thumb: the model is useful as a trend, its exact
numbers less so [18].

---

## 4. Running plan

The plan is rebuilt from your actual running every time the data changes (and when the date changes), so it adapts
after every activity. It only counts running.

### Goal parameters
| Distance | Minimum weeks | Recommended long run | Minimum peak km/week | Long-run cap | Long run ≤ share of week | Taper |
|---|---|---|---|---|---|---|
| 5 km | 6 | 7 km | 15 | 12 km | 45% | 1 week at 60% |
| 10 km | 6 | 11 km | 22 | 16 km | 45% | 1 week at 60% |
| Half marathon | 8 | 16 km | 30 | 22 km | 45% | 2 weeks: 80%, 55% |
| Marathon | 12 | 28 km | 45 | 32 km | 50% | 2 weeks: 70%, 50% |

Other distances (such as 10 miles or any distance you enter) are interpolated between these. Longer than a marathon
is treated as a marathon, with a warning that ultra-specific training is not included and without a time
prediction. Sources: [1], [5], [11].

### Phases
Counted back from race day: **taper** (above), **peak** (3–4 weeks), **build** (4–6 weeks), **base** (the rest).
Every 4th week (counted from when you made the plan) is a **lighter week**: about 25% less volume and a shorter long
run, so the training of the last weeks can sink in [5], [9]. The taper keeps intensity and frequency while volume goes
down 40–60%, the approach with the largest performance gain in a meta-analysis [11].

### Weekly distance
- **Start**: the highest of your 4-week average, last week's distance (experienced runners up to their block, others
  at most 30% above the 4-week average) [13], [7], and – after a short break – 70% of the volume before the break
  (experienced runners whose 4-week average fell below 1/1.2 of weeks 5–8) [15], [14]. A complete beginner starts at
  about 8 km/week.
- **Growth**: at most 10% a week [7], [8]; experienced runners 15% a week while below 90% of their block, since
  regaining a level goes faster than building it the first time (the 15% is a rule of thumb; background [13], [14],
  [15]: experienced runners get injured less, and much of years of training remains after a break).
- **Peak**: at least the minimum for the distance and enough for the recommended long run (which is at most half the
  week); a bit above what you run now; for experienced runners up to their block.
- **Without a history** you can enter your current km/week, longest recent run and a recent race time. Each counts
  only for the period it describes (4 weeks, 30 days, 120 days after you made the plan) and only where your
  activities show less; after that your real training takes over.

### Long run
- Grows at most 10% a week beyond your longest run of the last 30 days: single runs much longer than usual were
  linked to a higher injury risk in a cohort of 5,200 runners [6].
- Never shrinks (except in lighter weeks and the taper); peaks in the peak phase (80% of the cap in the base phase,
  90% in the build phase).
- At most half of the weekly distance, and no other run longer than three quarters of the long run. Daniels advises
  a long run of 25–30% of the week [1]; half is a rule of thumb that lets a low weekly volume still reach the long run
  a race needs. The three quarters follow Pfitzinger's medium-long run, which is clearly shorter than the long run
  [5].

### Signals that change this week (same as the Analysis advice, section 2)
| Signal | Effect | Sources |
|---|---|---|
| Load ratio > 1.3 (with more than 15 km in 7 days) | Rest of the week easy, long run does not grow, volume not above the 4-week average | [9], [10] |
| Ratio > 1.3 vs. the 4-week average but ≤ 1.3 vs. the block | Counts as a normal week, not a spike | [6], [10] |
| Efficiency drop | Hard sessions this week become easy runs | [12] |
| Form below −40% of fitness | Hard sessions this week become easy runs (explained as fatigue after a break when there was one) | [17], [18] |
| 14 days or more without running | This week easy only | [7] |
| VDOT changed by 0.5 or more | Training paces follow | [1] |

### Sessions
Most running is easy, below the aerobic threshold (about 80% of the time) [2], [3], [4]. Two quality days at most:
the first training day and one about midweek, never the day before the long run.

| Phase | Quality day 1 | Quality day 2 | Long run |
|---|---|---|---|
| Base | Easy + strides | Easy + strides (5+ days) or easy | Easy |
| Build | Threshold | Medium-long (marathon), threshold (half), intervals (shorter) | Marathon: every other week with a marathon-pace block |
| Peak | Threshold (half and longer) or intervals | Medium-long (marathon) or race-pace repetitions | Marathon: with marathon-pace block; shorter races: every other week a fast finish |
| Lighter week | Easy + strides | Easy | Easy |
| Taper | Threshold or intervals, half the volume | Easy | Shorter |

- **Easy run / long run**: at Daniels' E pace, heart rate below AeT [1], [2], [3], [4].
- **Strides**: 6–8 × 20 s fast but relaxed; plus optional strength training, which improves running economy [1], [20].
- **Threshold**: 1.6 km repetitions at T pace with 1 min jog ("cruise intervals"), in total about 10% of the weekly
  distance (at most 10 km) [1], [4].
- **Intervals**: 1 km repetitions at I pace with 2–3 min jog, about 8% of the weekly distance (at most 8 km) [1], [3], [2].
- **Race-pace repetitions**: 800 m (5 km), 1 km (10 km) or 3 km (longer) at goal pace [1].
- **Medium-long run**: a second longer easy run for the marathon [5], [2].
- **Marathon-pace block** in the long run: at most 18 km, 20% of the week and 60% of the run [1], [5].
- **Fast finish**: the last 25% of the long run (at most 5 km) at T pace [1], [5].
- **Race**: even pacing, the first kilometres slightly slower [1].
- Below 25 km/week no hard sessions (an easy base first) [1]. Hard sessions start with an easy warm-up, which
  improves performance [27]; below 35 km/week it is 1 km each way instead of 2 (rule of thumb, to keep the session in
  proportion to the week). With 3 days a week, one quality day.
- **Beginners** (not experienced and below 10 km/week): run/walk (1–2 min running, 1–2 min walking) until 20 minutes
  of continuous running. Walk breaks lowered cardiac strain and muscle pain at the same finishing time in non-elite
  marathon runners [28]; beginner programmes such as Couch-to-5K are built this way, but their exact build-up has no
  evidence base [29], so the 1–2 min and the 20 minutes are a rule of thumb.
- Each session shows the pace and heart-rate zone its key pace falls in (section 1).

### Feasibility checks
| Check | Limit | Sources |
|---|---|---|
| Too little time | Fewer weeks than the minimum for the distance | [5], [1] |
| Weekly distance cannot grow enough | Peak below 80% of the minimum (warning below 100%) | [7], [8], [5] |
| Long run cannot grow enough | Longest long run below 75% of the recommended one (warning below 100%); the message says whether weekly distance or the 10% growth limits it | [5], [7], [6] |
| Target time | Needs a VDOT above now + the realistic gain: about 1 VDOT per 5 weeks, more when regaining a level of the last 2 years (up to a third of a VDOT per week left) or for runners without history (up to ~0.4 per week, max 6) [16]. Warning when it needs more than half that gain | [1], [16] |
| No recent fitness estimate | The best VDOT of the last 2 years × 0.93 is used (detraining) | [13], [14], [15] |
| Long races below 60 km/week | Predictions are often a few minutes too fast | [1], [5] |

When the goal turns infeasible after a new activity you get a message once; the plan keeps a log of its last 20
updates.

---

## 5. Rules of thumb

Every rule above has a source. For these the exact number is LibreFlow's own choice, set near what the source says:
| Rule of thumb | Where it comes from |
|---|---|
| Long run at most 40% of a usual week (advice) / at most half the week (plan) | Daniels advises 25–30% [1]; LibreFlow is looser and relies on the 30-day growth limit for single runs [6] |
| No other run longer than three quarters of the long run | Pfitzinger's medium-long run [5] |
| A warning after 10 or more days in a row without a rest day | A passive rest day every week [21] |
| Fewer than 2.5 runs a week as a reason to add one | Aerobic exercise on 3–5 days a week [22] |
| Aerobic decoupling below 5% as the target, above 8% as a drift | Friel's 5% guideline [23]; decoupling and marathon performance [24] |
| Form limits −20% / −40% / +25% of fitness; 42/7-day time constants | Banister model [17] and its limits [18]; the performance manager [25] |
| 15% weekly growth for experienced runners rebuilding towards their block | Lower injury risk with experience [13]; detraining [14], [15] |
| 0.93 × the best VDOT of 2 years when there is no recent one | VO2max about 7% lower after 2–3 weeks without training [15] |
| 2 km instead of 4 km warm-up and cool-down below 35 km/week | Warm-up improves performance [27] |
| Run/walk for beginners, until 20 minutes of continuous running | Run/walk strategy [28]; beginner programmes [29] |
| A shoe reminder at 400 km by default | Cushioning lost with distance [26] |

---

## 6. Sources

1. Daniels J. *Daniels' Running Formula*, 3rd ed. Human Kinetics, 2014. VDOT, training paces E/M/T/I, limits per
   session type. ISBN 978-1-4504-3183-5 ([Open Library](https://openlibrary.org/search?isbn=9781450431835))
2. Seiler KS, Kjerland GØ. Quantifying training intensity distribution in elite endurance athletes: is there evidence
   for an "optimal" distribution? *Scand J Med Sci Sports* 2006;16:49–56.
   [doi:10.1111/j.1600-0838.2004.00418.x](https://doi.org/10.1111/j.1600-0838.2004.00418.x)
3. Stöggl T, Sperlich B. Polarized training has greater impact on key endurance variables than threshold, high
   intensity, or high volume training. *Front Physiol* 2014;5:33.
   [doi:10.3389/fphys.2014.00033](https://doi.org/10.3389/fphys.2014.00033)
4. Casado A, Hanley B, Santos-Concejero J, Ruiz-Pérez LM. World-class long-distance running performances are best
   predicted by volume of easy runs and deliberate practice of short-interval and tempo runs. *J Strength Cond Res*
   2021;35:2525–2531. [doi:10.1519/JSC.0000000000003176](https://doi.org/10.1519/JSC.0000000000003176)
5. Pfitzinger P, Douglas S. *Advanced Marathoning*, 3rd ed. Human Kinetics, 2019. Long and medium-long runs,
   marathon-pace runs, recovery weeks. ISBN 978-1-4925-6866-7 ([Open Library](https://openlibrary.org/search?isbn=9781492568667))
6. Frandsen JSB, Hulme A, Parner ET, et al. How much running is too much? Identifying high-risk running sessions in a
   5200-person cohort study. *Br J Sports Med* 2025;59:1203–1210.
   [doi:10.1136/bjsports-2024-109380](https://doi.org/10.1136/bjsports-2024-109380)
7. Nielsen RO, et al. Excessive progression in weekly running distance and risk of running-related injuries: an
   association which varies according to type of injury. *J Orthop Sports Phys Ther* 2014;44:739–747.
   [doi:10.2519/jospt.2014.5164](https://doi.org/10.2519/jospt.2014.5164)
8. Buist I, et al. No effect of a graded training program on the number of running-related injuries in novice
   runners: a randomized controlled trial. *Am J Sports Med* 2008;36:33–39.
   [doi:10.1177/0363546507307505](https://doi.org/10.1177/0363546507307505)
9. Gabbett TJ. The training–injury prevention paradox: should athletes be training smarter and harder? *Br J Sports
   Med* 2016;50:273–280. [doi:10.1136/bjsports-2015-095788](https://doi.org/10.1136/bjsports-2015-095788)
10. Impellizzeri FM, et al. Acute:chronic workload ratio: conceptual issues and fundamental pitfalls. *Int J Sports
    Physiol Perform* 2020;15:907–913. [doi:10.1123/ijspp.2019-0864](https://doi.org/10.1123/ijspp.2019-0864)
11. Bosquet L, Montpetit J, Arvisais D, Mujika I. Effects of tapering on performance: a meta-analysis. *Med Sci
    Sports Exerc* 2007;39:1358–1365. [doi:10.1249/mss.0b013e31806010e0](https://doi.org/10.1249/mss.0b013e31806010e0)
12. Buchheit M. Monitoring training status with HR measures: do all roads lead to Rome? *Front Physiol* 2014;5:73.
    [doi:10.3389/fphys.2014.00073](https://doi.org/10.3389/fphys.2014.00073)
13. van Poppel D, van der Worp M, Slabbekoorn A, et al. Risk factors for overuse injuries in short- and long-distance
    running: a systematic review. *J Sport Health Sci* 2021;10:14–28.
    [doi:10.1016/j.jshs.2020.06.006](https://doi.org/10.1016/j.jshs.2020.06.006)
14. Mujika I, Padilla S. Detraining: loss of training-induced physiological and performance adaptations. Part I and
    Part II. *Sports Med* 2000;30:79–87 and 145–154.
    [doi:10.2165/00007256-200030020-00002](https://doi.org/10.2165/00007256-200030020-00002),
    [doi:10.2165/00007256-200030030-00001](https://doi.org/10.2165/00007256-200030030-00001)
15. Coyle EF, Martin WH, Bloomfield SA, Lowry OH, Holloszy JO. Time course of loss of adaptations after stopping
    prolonged intense endurance training. *J Appl Physiol* 1984;57:1857–1864.
    [doi:10.1152/jappl.1984.57.6.1857](https://doi.org/10.1152/jappl.1984.57.6.1857)
16. Milanović Z, Sporiš G, Weston M. Effectiveness of high-intensity interval training (HIT) and continuous endurance
    training for VO2max improvements: a systematic review and meta-analysis of controlled trials. *Sports Med*
    2015;45:1469–1481. [doi:10.1007/s40279-015-0365-0](https://doi.org/10.1007/s40279-015-0365-0)
17. Morton RH, Fitz-Clarke JR, Banister EW. Modeling human performance in running. *J Appl Physiol*
    1990;69:1171–1177. Fitness–fatigue model, TRIMP.
    [doi:10.1152/jappl.1990.69.3.1171](https://doi.org/10.1152/jappl.1990.69.3.1171)
18. Hellard P, Avalos M, Lacoste L, Barale F, Chatard JC, Millet GP. Assessing the limitations of the Banister model
    in monitoring training. *J Sports Sci* 2006;24:509–520.
    [doi:10.1080/02640410500244697](https://doi.org/10.1080/02640410500244697)
19. Heiderscheit BC, Chumanov ES, Michalski MP, Wille CM, Ryan MB. Effects of step rate manipulation on joint
    mechanics during running. *Med Sci Sports Exerc* 2011;43:296–302.
    [doi:10.1249/MSS.0b013e3181ebedf4](https://doi.org/10.1249/MSS.0b013e3181ebedf4)
20. Blagrove RC, Howatson G, Hayes PR. Effects of strength training on the physiological determinants of middle- and
    long-distance running performance: a systematic review. *Sports Med* 2018;48:1117–1149.
    [doi:10.1007/s40279-017-0835-7](https://doi.org/10.1007/s40279-017-0835-7)
21. Meeusen R, Duclos M, Foster C, et al. Prevention, diagnosis, and treatment of the overtraining syndrome: joint
    consensus statement of the European College of Sport Science and the American College of Sports Medicine.
    *Med Sci Sports Exerc* 2013;45:186–205. Recommends at least one passive rest day a week.
    [doi:10.1249/MSS.0b013e318279a10a](https://doi.org/10.1249/MSS.0b013e318279a10a)
22. Garber CE, Blissmer B, Deschenes MR, et al. Quantity and quality of exercise for developing and maintaining
    cardiorespiratory, musculoskeletal, and neuromotor fitness in apparently healthy adults: guidance for prescribing
    exercise (ACSM position stand). *Med Sci Sports Exerc* 2011;43:1334–1359.
    [doi:10.1249/MSS.0b013e318213fefb](https://doi.org/10.1249/MSS.0b013e318213fefb)
23. Friel J. Aerobic endurance and decoupling. TrainingPeaks (coaching article).
    [trainingpeaks.com/blog/aerobic-endurance-and-decoupling](https://www.trainingpeaks.com/blog/aerobic-endurance-and-decoupling/)
24. Smyth B, Maunder E, Meyler S, Hunter B, Muniz-Pumares D. Decoupling of internal and external workload during a
    marathon: an analysis of durability in 82,303 recreational runners. *Sports Med* 2022;52:2283–2295.
    [doi:10.1007/s40279-022-01680-5](https://doi.org/10.1007/s40279-022-01680-5)
25. Allen H, Coggan AR, McGregor S. *Training and Racing with a Power Meter*, 3rd ed. VeloPress, 2019. Performance
    manager: 42-day fitness, 7-day fatigue, form. ISBN 978-1-937715-93-9
    ([Open Library](https://openlibrary.org/search?isbn=9781937715939))
26. Cook SD, Kester MA, Brunet ME. Shock absorption characteristics of running shoes. *Am J Sports Med*
    1985;13:248–253. [doi:10.1177/036354658501300406](https://doi.org/10.1177/036354658501300406)
27. Fradkin AJ, Zazryn TR, Smoliga JM. Effects of warming-up on physical performance: a systematic review with
    meta-analysis. *J Strength Cond Res* 2010;24:140–148.
    [doi:10.1519/JSC.0b013e3181c643a0](https://doi.org/10.1519/JSC.0b013e3181c643a0)
28. Hottenrott K, Ludyga S, Schulze S, Gronwald T, Jäger FS. Does a run/walk strategy decrease cardiac stress during
    a marathon in non-elite runners? *J Sci Med Sport* 2016;19:64–68.
    [doi:10.1016/j.jsams.2014.11.010](https://doi.org/10.1016/j.jsams.2014.11.010)
29. Relph N, Taylor PJ, Christian DL, Dey P, et al. "Couch-to-5k or Couch to Ouch to Couch!?" Who takes part in
    beginner runner programmes in the UK and is non-completion associated with musculoskeletal injury? *Int J Environ
    Res Public Health* 2023;20:6682. [doi:10.3390/ijerph20176682](https://doi.org/10.3390/ijerph20176682)
