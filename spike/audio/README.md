# Venue audio for trigger work

Put WAVs here and commit them. This is the one artefact from a session that is
small enough to move around: a 10-second mono 22 kHz WAV is about 440 KB, next
to hundreds of megabytes for the clip it came from — and for deciding what a hit
sounds like, the audio *is* the signal. The video adds nothing to that question.

## Getting one off a clip, on a Mac, with nothing installed

```
afconvert -f WAVE -d LEI16@22050 -c 1 clips/tee_01.mov audio/tee_01.wav
```

`afconvert` ships with macOS. If it refuses the `.mov`, export **Audio Only**
from QuickTime and convert the resulting `.m4a` the same way.

22 kHz is deliberate. Bat-on-ball energy runs well past 5 kHz, so 22 kHz
sampling keeps everything that matters up to 11 kHz and halves the file against
48 kHz.

## Read this before wondering why a clip is silent

iPhone **slow-motion clips frequently lose or time-stretch their audio** when
exported or shared from Photos. If a WAV comes out silent, or its impulses land
at times that do not match what you see in the video, that is the cause. AirDrop
the original clip rather than a trimmed or shared copy.

If the original genuinely has no usable audio at 240 fps, that is itself a
finding, and a serious one: it would mean the audio trigger cannot work on
slow-motion footage at all and capture has to be manual or vision-triggered.
Worth establishing early rather than discovering at a field.

## Using them

```
python audio_lab.py audio/tee_01.wav                        # list every impulse
python audio_lab.py audio/tee_01.wav --labels 1.83 4.20     # ...and what separates hits
python audio_lab.py audio/                                  # every wav here
python audio_lab.py --selftest                              # prove the tool first
```

Labels are the times in seconds of real contact. They are what turns a list of
loud moments into a measurement of what distinguishes them — without labels the
tool can only report what it found, not which finding was right.

Note the times off the video, or read them off the first run: with one swing per
clip, the loudest impulse is almost always the hit.

## What to record if you are going out specially

The valuable clip is **not** a clean swing. It is a swing with the venue's worst
noise in it — the bat dropped, the fence rattled, someone shouting, a car going
past. A tool that separates hits from silence is not worth writing; separating
them from everything else in a car park is the whole problem.
