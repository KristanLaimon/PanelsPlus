--[[
The guide: what Ink Away can do that a glance doesn't show, as short cards
under topics, opened from Settings (ink/view/guide.lua shows it). Plain data:
adding a feature is adding a card here, in the same commit, and
tests/guide.lua checks every card (its icons exist, its text is short, its
"Show me" opens something).

A topic: { id, title, line (under its title in the index), icon, when, cards }.
A card:
  glyph or icon   a gesture glyph (ink/icons/ges_*) or a tool icon (ink/icons)
  title, text     what it is, in a few words and a sentence or two
  when            where it applies (Guide.WHEN; a list means all of them)
  show            the sheet its "Show me" opens (ink/view/guide.lua)
  gesture_of      a book feature: the card shows the gesture it got
                  (ink/reader/entrygestures.lua), not a fixed one
  trigger         a gesture or pen button (ink/actions.lua): its current action
                  is the card's title, and a trigger set to Nothing hides it
Plain Lua: the headless tests drive it.
]]

local Guide = {}

-- Longest a card's text may be, so the guide stays short.
Guide.MAX_TEXT = 170

-- Where a card or topic applies, from what the view knows (see context in
-- ink/view/guide.lua).
Guide.WHEN = {
    canvas = "the canvas, not over a book",
    book = "over a book (annotating it, or its notes)",
    pen_capable = "KOReader can hand the pen to Ink Away",
    pen = "palm rejection is on, so the pen and its buttons are Ink Away's",
    pressure = "a reader whose pen can give its pressure (Pen pressure (Beta) is offered)",
    colour = "a colour screen",
    android = "Android",
    boox = "a Boox Ink Away asks for the fast refresh on",
}

Guide.TOPICS = {
    { id = "around", title = "Getting around", line = "Tools, zoom and saving", icon = "pan", cards = {
        { glyph = "ges_tap", title = "Tools and their settings",
          text = "Tap a tool to use it, and tap it again for its settings." },
        { glyph = "ges_tap", title = "More room",
          text = "The small tab at the end of the toolbar folds it away, and brings it back." },
        { glyph = "ges_pinch", title = "Zoom", when = "canvas",
          text = "The + and \u{2212} in the corner zoom in and out, and so does a pinch." },
        { icon = "pan", title = "Move around", when = "canvas",
          text = "Pan, above the zoom, moves the page; tap it again to go back to your tool. Two fingers move the page with any tool." },
        { icon = "file", title = "It saves itself", when = "canvas",
          text = "Every drawing and notebook is a file that saves as you go. File has Rename, Duplicate, Export and New." },
        { icon = "library", title = "Where to start", when = "canvas",
          text = "Settings, When Ink Away opens: the last document, the Library or your Notebooks." },
    } },
    { id = "pens", title = "Pens", line = "Your pens, kinds and pressure", icon = "pen", cards = {
        { glyph = "ges_tap", title = "Take up a pen", show = "pens",
          text = "Tap one of your saved pens in the pen menu. Changing its size or colour changes that pen." },
        { icon = "pen", title = "A new pen",
          text = "+ in the pen menu asks for its kind (Fineliner, Ballpoint, Fountain, Pencil, Marker, Highlighter, Watercolor...), then its size and colour." },
        { glyph = "ges_hold", title = "Move, copy or remove",
          text = "Hold a saved pen." },
        { glyph = "ges_hold_still", title = "Straight lines",
          text = "Hold the pen still at the end of a stroke: a rough line, box, ellipse or triangle snaps clean. Writing is left alone." },
        { icon = "pen", title = "Your pens on the page", when = "canvas", show = "pen_input",
          text = "A strip of your first four pens, one tap away: Pen and input, Your pens on the page." },
        { icon = "pen", title = "Pen pressure", when = "pressure", show = "pen_input",
          text = "Ballpoint, Fountain, Calligraphy and Pencil can follow how hard you press: Pen and input, Pen pressure (Beta), with Palm rejection on." },
        { glyph = "ges_hold", title = "Your own brushes", when = "canvas",
          text = "Make a brush in the list of kinds; hold it there to delete it." },
    } },
    { id = "erase", title = "Erasing", line = "Part of a stroke, or all of it", icon = "eraser", cards = {
        { icon = "eraser", title = "Part or whole", show = "eraser",
          text = "The eraser rubs out what it touches; Erase whole strokes takes each stroke it crosses." },
        { icon = "eraser", title = "Text and pictures", when = "canvas",
          text = "Protect text from eraser and Erase pictures, in the eraser's menu, decide what it may take." },
        { glyph = "ges_pen_button", trigger = "pen_eraser", when = "pen_capable",
          text = "The pen's eraser end, for as long as it touches." },
        { glyph = "ges_two_tap", trigger = "two_tap", text = "Two-finger tap." },
        { glyph = "ges_two_double_tap", trigger = "two_double_tap", text = "Two-finger double tap." },
    } },
    { id = "make", title = "Shapes, text and pictures", line = "Everything besides ink", icon = "shape", cards = {
        { icon = "shape", title = "Shapes", show = "shapes",
          text = "Lines, curves, arrows, boxes, ellipses and triangles, filled or outlined." },
        { glyph = "ges_hold", title = "Paint bucket", when = "canvas",
          text = "Tap an area to fill it; hold the bucket in the shapes menu to pick its colour." },
        { icon = "text", title = "Text",
          text = "Tap where it should go. Format stays open while you pick styles, colours, highlights, lists, spacing and the font; on lined paper text sits on the lines." },
        { icon = "text", title = "Turn text",
          text = "Drag the ring above an open text box to turn it to any angle, or pick Reads down or Reads up in Format, Paragraph, for a book's margins." },
        { icon = "text", title = "Checklists",
          text = "Format, Paragraph, Checklist puts a box before each line. Tap a box to tick it, with the text open or closed." },
        { glyph = "ges_hold", title = "Paste into text",
          text = "Hold inside the text box you are writing in." },
        { icon = "image", title = "Pictures",
          text = "Image adds one from a file or from the web. Move, resize or turn it; Remove background cuts it out." },
        { glyph = "ges_hold", title = "Trace over a picture", when = "canvas",
          text = "Image, Background puts a picture behind the page. Hold New drawing to start a drawing from one." },
        { icon = "file", title = "Layers", when = "canvas", show = "layers",
          text = "File, Layers splits a drawing into layers. The strip at the right adds one or picks where you draw; tap that one for its menu." },
    } },
    { id = "select", title = "Select and edit", line = "The lasso, links and text", icon = "lasso", cards = {
        { icon = "lasso", title = "Lasso",
          text = "Loop writing, shapes, pictures or text for its menu: cut, copy, duplicate, turn, flip, colour, size, opacity, to front, delete." },
        { glyph = "ges_tap", title = "Select a word",
          text = "Tap a word twice in the text you are writing in; drag across text to select more." },
        { icon = "text", title = "Convert to text",
          text = "Lasso printed handwriting and Convert to text makes it a text box. One undo brings the writing back." },
        { icon = "overview", title = "Paste anywhere", when = "canvas",
          text = "Cut or copy, then on any page of any notebook: the page menu, Paste." },
        { icon = "lasso", title = "Links", when = "canvas",
          text = "Link to page in the lasso's menu makes it a link: tap it with Pan, or a finger with palm rejection on, to jump there; Back returns." },
        { glyph = "ges_tap", title = "One shape or picture",
          text = "With the lasso, tap a shape or picture to pick it out: move, resize, turn or delete it. On a drawing, a hold with Pan does it too." },
    } },
    { id = "notebooks", title = "Notebooks", line = "Pages, papers and PDFs", icon = "notebook", when = "canvas", cards = {
        { glyph = "ges_two_swipe_side", title = "Turn pages",
          text = "The arrows in the bar at the bottom, or swipe two fingers sideways." },
        { glyph = "ges_hold", title = "First or last page",
          text = "Hold the previous or next arrow." },
        { glyph = "ges_tap", title = "The page menu",
          text = "Tap the page number: go to a page, rename, star, insert, duplicate, move, paper, templates, paste or delete." },
        { icon = "notebook", title = "Papers and planners",
          text = "Lined, grid, dotted, Cornell, daily, weekly, monthly, a habit tracker and more, for each page." },
        { icon = "notebook", title = "Paper colour", show = "paper_colour",
          text = "Settings, beside the paper or the grid: cream, sandpaper, kraft, chalkboard and more (white or black on grey). On a dark one black ink shows white." },
        { icon = "overview", title = "A contents page",
          text = "The page menu, Make a contents page: every titled page becomes a link to it. Go to the contents page is there too, and can be a gesture." },
        { icon = "file", title = "PDFs",
          text = "Import a PDF to write on its pages, then export it back to PDF." },
    } },
    { id = "library", title = "Library and Browse", line = "Folders, search and the trash", icon = "library", when = "canvas", cards = {
        { glyph = "ges_hold", title = "The Library", show = "library",
          text = "Tap to open, hold for rename, move, duplicate, export or delete. + makes a drawing, a notebook or a folder." },
        { glyph = "ges_hold", title = "Browse",
          text = "A folder's notebooks are tabs beside their pages. Hold a tab to rename, colour or reorder it; hold a page to star, move or copy it." },
        { glyph = "ges_two_swipe_up", trigger = "two_swipe_up", text = "Long two-finger swipe up." },
        { icon = "search", title = "Search",
          text = "By name, or tick look inside pages to search typed and converted text too." },
        { icon = "library", title = "Trash", show = "trash",
          text = "Deleted things, a book's annotations too, wait 30 days and go back where they were." },
    } },
    { id = "books", title = "Books", line = "Annotations and book notes", icon = "booknotes", when = "book", cards = {
        { gesture_of = "annotate", icon = "pen", title = "Annotate the book",
          text = "Ink stays with the words when the font changes. Also in the reader menu: Tools, Ink Away." },
        { icon = "highlighter", title = "The highlighter",
          text = "A highlighter stroke over text becomes the reader's own highlight, from the first word it touches to the last. Over empty space it stays ink." },
        { glyph = "ges_pen_button", title = "Highlight while reading", when = "pen_capable",
          text = "No need to annotate: hold the pen's side button (the one set to Highlighter) and run the pen over a line while reading." },
        { gesture_of = "booknotes", icon = "booknotes", title = "Book notes",
          text = "Quick notes for the book, in a window over the page, a page for each chapter. Fullscreen gives more room." },
        { icon = "menu", title = "Toolbar side", show = "book_ink",
          text = "Book ink, Toolbar: on the left, right, top or bottom." },
        { icon = "pen", title = "Reading without ink",
          text = "Book ink, Show ink while reading: off shows the plain book. Your ink stays." },
        { icon = "eraser", title = "Start again",
          text = "Book ink, Delete all annotations on this book. They wait in the trash for 30 days." },
    } },
    { id = "gestures", title = "Gestures and pen buttons", line = "Your shortcuts", icon = "ges_two_tap", cards = {
        { glyph = "ges_two_tap", trigger = "two_tap", text = "Two-finger tap." },
        { glyph = "ges_two_double_tap", trigger = "two_double_tap", text = "Two-finger double tap." },
        { glyph = "ges_two_swipe_side", trigger = "two_swipe_left", text = "Two-finger swipe left." },
        { glyph = "ges_two_swipe_side", trigger = "two_swipe_right", text = "Two-finger swipe right." },
        { glyph = "ges_two_swipe_up", trigger = "two_swipe_up", text = "Long two-finger swipe up." },
        { glyph = "ges_two_swipe_down", trigger = "two_swipe_down", text = "Long two-finger swipe down." },
        { glyph = "ges_pen_button", trigger = "pen_side", when = "pen_capable", text = "Hold the pen's side button while drawing." },
        { glyph = "ges_pen_button", trigger = "pen_eraser", when = "pen_capable", text = "The pen's eraser end." },
        { icon = "menu", title = "Make them yours", show = "gestures",
          text = "Gestures and pen buttons gives each one an action, and the page turn buttons too: undo, lasso, a saved pen, hiding the toolbar and more." },
    } },
    { id = "reader", title = "Your reader", line = "Pen, screen and refresh", icon = "reader", cards = {
        { icon = "pen", title = "Palm rejection", when = "pen_capable", show = "pen_input",
          text = "For pen readers: rest your hand while you write. Finger on the page sets what a finger does then." },
        { icon = "pen", title = "The pen on menus", when = "pen",
          text = "Pen and input, Pen taps menus and buttons: work the toolbar and menus with the pen too." },
        { glyph = "ges_tap", title = "Test pen and touch", when = { "canvas", "pen_capable" }, show = "pen_test",
          text = "Shows how your pen, its buttons and your hand arrive. Handy in a bug report." },
        { icon = "appearance", title = "Dark mode", show = "appearance",
          text = "Settings, the round button by Guide: light, dark, or as KOReader's night mode. The page keeps its colours." },
        { icon = "menu", title = "Colour", when = "colour",
          text = "Settings: the theme colour, and Colour while drawing." },
        { icon = "menu", title = "Updates", when = "canvas", show = "updates",
          text = "Settings, Updates: the latest release, and prereleases apart. Once a day, opening on Wi-Fi, Ink Away looks; a dot on Settings means news." },
        { icon = "menu", title = "Ghosting", when = "canvas",
          text = "Settings, Ghosting: a full refresh every few strokes clears the faint marks fast drawing leaves. The Refresh the screen button below it does one now." },
        { icon = "pen", title = "Fast refresh on a Boox", when = "boox", show = "pen_input",
          text = "Pen and input, Fast refresh while drawing: ink shows with the Boox's fast refresh as you write." },
        { icon = "menu", title = "Faster drawing", when = "android", show = "device_tips",
          text = "What to set on this reader for quicker ink." },
    } },
    { id = "export", title = "Export", line = "PNG, PDF and more", icon = "file", when = "canvas", cards = {
        { icon = "file", title = "PNG", show = "export",
          text = "File, Export: transparent or white, the whole page or an area you pick, with or without the grid." },
        { icon = "file", title = "PDF",
          text = "A notebook or some of its pages, with bookmarks for titled pages and links that work." },
        { glyph = "ges_hold", title = "A whole folder",
          text = "Hold a folder in the Library, Export as PDF." },
        { icon = "file", title = "Bookshelf",
          text = "With the Bookshelf plugin installed, save a drawing as one of its ornaments." },
    } },
}

-- Does `when` (nil, a key, or a list of keys) hold in `ctx`?
function Guide.applies(when, ctx)
    if when == nil then return true end
    if type(when) == "table" then
        for _i, w in ipairs(when) do if not ctx[w] then return false end end
        return true
    end
    return ctx[when] and true or false
end

-- The cards of `topic` that apply in `ctx`, ready to show: each a copy with
-- its glyph, title and text worked out. `ctx.bindings` are the gestures'
-- actions (ink/actions.lua), `ctx.placed` the book gestures' setup, and
-- `label(id)` an action's name; `gesture(ges)` a book gesture's glyph and words.
function Guide.cards(topic, ctx)
    local out = {}
    for _i, c in ipairs(topic.cards) do
        if Guide.applies(c.when, ctx) then
            local card = { glyph = c.glyph, icon = c.icon, title = c.title, text = c.text, show = c.show }
            local keep = true
            if c.trigger then
                local action = ctx.bindings and ctx.bindings[c.trigger]
                if not action or action == "nothing" then keep = false
                else card.title = ctx.label and ctx.label(action) or action end
            end
            if keep and c.gesture_of then
                local ges = ctx.placed and ctx.placed[c.gesture_of]
                local g = ges and ctx.gesture and ctx.gesture(ges)
                if g then card.glyph, card.how = g.glyph, g.text end
            end
            if keep then out[#out + 1] = card end
        end
    end
    return out
end

-- The topics with something to show in `ctx`.
function Guide.topics(ctx)
    local out = {}
    for _i, t in ipairs(Guide.TOPICS) do
        if Guide.applies(t.when, ctx) and #Guide.cards(t, ctx) > 0 then out[#out + 1] = t end
    end
    return out
end

function Guide.topic(id)
    for _i, t in ipairs(Guide.TOPICS) do if t.id == id then return t end end
end

return Guide
