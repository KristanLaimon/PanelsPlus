# Scott Pilgrim Vol. 5 Safe review

The 18 choices in the version 1 export at 14:49 UTC matched the saved
review bases and report
`bf520fb845a27e3122273b20d87e1ba303b03e0b687ffd26b42bdb636afae0ee`.
All chosen crops already matched the dataset, including pages 201, 205
and 216, whose session flags said they had not been applied. The volume
uses comic order, top to bottom and left to right within a row.

Safe now distinguishes a small overlap from a tilted crop edge from a
real vertical stack. This fixes the three remaining order-only pages,
13, 101 and 129, and preserves the accepted left-to-right order on 15.
A three-sided, nearly full-width strip can survive the small-component
filter, which recovers panel five on page 108. When connected frames
cannot be accepted, two comparable tall areas separated by an ink-free
gutter can recover faded panels, as on 139 and 140. Full-page artwork
with minor lettering and dark illustrations with weak frame evidence
stay together.

Earlier experiments split the sketch sheet on page 211 and collapsed
the three framed photographs on page 187. The final guards protect both.
An experiment to add the isolated chapter card on page 175 failed the
existing coverage check. That experiment was removed and the coverage
and panel count guards remain in force.

Both runs used the same final mapping and the production evaluator
at IoU 0.50 or 35 px edge tolerance.

| Metric | Before | After |
|---|---:|---:|
| Expected / detected / matched panels | 837 / 852 / 826 | 837 / 840 / 832 |
| F1 | 97.81% | 99.22% |
| Mean IoU across pages with matches | .9679 | .9707 |
| Complete pages in order | 203 / 218 | 214 / 218 |
| Correct relative order of matched pairs | 1663 / 1672 | 1677 / 1679 |
| Complete pages in this export | 3 / 18 | 14 / 18 |

The 11 pages gained were 13, 90, 101, 108, 129, 139, 140, 177, 201, 205
and 216. No previously correct page was lost. All four remaining
differences are in the export:

- Page 148 merges several panels within the dark surround.
- Page 175 misses the large detached chapter card.
- Page 198 splits an editorial page that the review keeps whole so its
  prose and accompanying sketches can be read together.
- Page 199 splits the first left crop and visits the last left crop after
  entering the right column. This is the only remaining order inversion
  among matched panels.

The editorial page on 198 and the numbered reading steps on 199 may
look similar to a detector, but the reviewed difference is consistent
with their reading roles. The detached card on 175 is another example
where the intended reading step depends on the content.

Chainsmoker and Nagatoro produced identical full-volume Safe diagnostics.
The new geometry and Scott Pilgrim regressions fail on the original Safe
implementation and pass with these changes. The targeted tests and scoped
Safe and Smart benchmarks passed. The previous Safe baseline was archived
and the other baseline records were retained. The Scott Pilgrim Safe
reviewer report was refreshed with Bun stopped. Device behavior has not
been tested.
