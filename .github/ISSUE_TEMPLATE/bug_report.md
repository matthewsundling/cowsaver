---
name: Bug report
about: Something is broken
labels: bug
---

## `make doctor` output

<!--
REQUIRED. Paste the whole thing.

The legacy screensaver host is a separate macOS component. `make doctor` records the
environment that built the installed saver, which makes a report reproducible.
-->

```
paste here
```

## What happened

<!-- Including "nothing happened" and "the screen went grey and stayed grey". -->

## What you expected

## Steps to reproduce

## Which front-end

- [ ] The screensaver (`Cowsaver.saver`, via System Settings)
- [ ] The standalone app (`Cowsaver.app`)
- [ ] `cowsaver-cli`

## If it is a rendering problem

<!-- A screenshot helps. If the screensaver shows nothing at all, try:
       ./build/Cowsaver.app/Contents/MacOS/Cowsaver --window
     If the app renders and the screensaver does not, that narrows it a great deal. -->

## Anything in Console.app?

<!-- Cowsaver logs with the prefix [Cowsaver]. Filter on that. -->

---

<!--
Not a bug, but the right place to raise it:

FORTUNE QUOTES. If a quote is misattributed, misquoted, or is material you hold rights to
and would rather not see redistributed, open an issue and say so — you do not need to argue
the point and we will remove it. Attributions in the fortune database are unverified;
upstream says so itself. See Resources/fortune-curated/provenance.md.

If it is a rights claim you would rather not detail in public, say that without details and
we will find another channel.

COW ART. If you drew one of these cows and want the credit corrected or the art removed,
same: open an issue.
-->
