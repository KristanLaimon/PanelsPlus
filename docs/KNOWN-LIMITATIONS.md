# Known Limitations

## 1. Pages with intersecting speech bubbles take the whole page as one big panel.
Due to the nature of KOReader's native reader "Exact Mode", and (initially) in the search for performance, full pages with speech bubbles that intersect across multiple panels aren't zoomed into individual panels because the detector takes the whole page as a single big panel instead of cutting those panels and the main dialog bubble.

<table align="center" width="80%">
  <tr>
    <td align="center" width="50%">
      <img src="../.github/limitation-dark-1.png" alt="Normal View" width="100%">
      <br>
      <sub>Normal View</sub>
    </td>
    <td align="center" width="50%">
      <img src="../.github/limitation-dark-2.png" alt="One big panel..." width="100%">
      <br>
      <sub>One big panel...</sub>
    </td>
  </tr>
</table>

**Why?**  
Normally the detection algorithm looks for clear panel boundaries, but when speech bubbles intersect multiple panels, the detection logic groups them all together into one large panel. In the future maybe I'll add better handling to separate them.

### When panels and dialogs are well-separated:
It works fine if the panels and speech bubbles have clear spacing between each other or they are encapsulated in their respective panels:

<p align="center">
  <img src="../.github/limitation-dark-ok-1.png" alt="Normal page (no plugin activated yet)" width="60%">
  <br>
  <sub>Normal page (no plugin activated yet)</sub>
</p>

<table align="center" width="95%">
  <tr>
    <td align="center" width="25%">
      <img src="../.github/limitation-dark-ok-2.png" alt="Panel 1" width="100%">
      <br>
      <sub>Panel 1</sub>
    </td>
    <td align="center" width="25%">
      <img src="../.github/limitation-dark-ok-3.png" alt="Panel 2" width="100%">
      <br>
      <sub>Panel 2</sub>
    </td>
    <td align="center" width="25%">
      <img src="../.github/limitation-dark-badorder-upsi.png" alt="Panel 3" width="100%">
      <br>
      <sub>Panel 3</sub>
    </td>
    <td align="center" width="25%">
      <img src="../.github/limitation-dark-ok-4.png" alt="Panel 4" width="100%">
      <br>
      <sub>Panel 4</sub>
    </td>
  </tr>
</table>

<p align="center">
  <sub>With plugin zooming</sub>
</p>

---