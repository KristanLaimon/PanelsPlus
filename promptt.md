Lets create a skill locally in this project, will be commited. IN .agents/skills. It will be named panelsplus-crossplugin-dev. In this skill you will save the following RULES and context/information:

this project Panels+ wants/have compatibility with other people's plugins instead of reinventing the wheel or just copy them, search for a way to integrate them, thats my phylosophy, as Panels+ just does features related to panels, no more, for that, that's what the other plugins are for, so lets add integration or at least compatibility with them. There are different levels of integration:

Lets say we have PluginA and PluginB.  (2 plugins)

1. Minimal
This means, that if both plugins are installed, they do not conflict each other or simply koreader doesn't crash thats it. No real integration. Just no crash.

2. OneWay Knowledge
This means, that 1 plugin knows the other plugin is installed/available and gives support for it, while the other plugin doesn't know anything. One way knowledge.
This knowledge has 2 subtypes:
- Not visual: Theres no visual cue in UI.
- Visual: Theres visual in UI and even gives options or settings related to it.

2. BothWays Knowledge
Both plugins can recognize each other and give support each other.
This knowledge has 2 subtypes:
- Not visual: Theres no visual cue in UI.
- Visual: Theres visual in UI and even gives options or settings related to it.

3. <No relationship>
This means we know for sure theres no relation. We're certaing.

4. <Unknown Behavior Relationship>
This means we do not know if it works or not, we need to test them together first.
Normally this kind of relationship is between 2 plugins and neither of them are Panels+.

In all relationships there should be always the versions between those plugins:

Oneway |  Panels+ >= v1.3.0    ---->     kobo.koplugin >= v0.4.1

This is an example of an entry and coutns as documentation found in: <cwd_panelsplus>/references-repos/plugin-relationships.md and always look there
first when starting the ai session when using this skill.

koreader repo is the only exception is not a plugin its literally the source code where all plugins are working on.

------

So far I know these are the actual plugin-relationships, which are located (or create if doesn't exist) in <cwd_panelsplus>/references-repos/plugin-relationships.md

Oneway |  Panels+ >= v1.3.0    ---->     kobo.koplugin  >= v0.4.1
Oneway |  Meguru  >= v1.7.0    ---->     Panels         >= v1.5.1

<No relationship> | Panels+ >= 1.5.1  <---->   ink-away >= v4.4.4
<Unknown Behavior Relationship> | ink-away >= v4.4.4 ----> Meguru >= v1.7.1

In case user is talking about another plugin or the relationship is not clear, ask to user prompter first.

---

Resources:

Each plugin has 2 source codes:

- Stable Release: The latest release from release page from any plugin. Normally found from their github repos.
The link for their latest release should be in plugin-releases-links.md in <cwd_panelsplus>/references-repos/plugin-releases-links.md
This will have each plugin with 3 links the github link and their latest release (/latest ,generic) and a link to the link release specifically
that actual panels+ has compatibility tested, (which versions can be found in <cwd_panelsplus>/references-repos/references-latest-stable-builds/***__v*.*.*
so the ***__v*.*.* is the version, all builds with pinned versions will be folders with that naming convention, state this as naming convention)

- Git Rolling Release: Which is the git submodule to the latest commit in ./references-repos/  (all folder related to plugins end with .koplugin)

This includes even for Panels+


So the point is that, when doing integrations, integrations should be tested with 2 priority mindset:

---

Testing:

Creating tests, which they belong in
1. Against the corresponding stable release first
    - ./tests/plugin-compatibility/<pluginanme__v.*.*.*/**_spec.lua> (stable release, there could be 1 of more of same plugin but always with differente versions)

2. Against the git rolling release version
    - ./tests/plugin-compatibility/<pluginanme__rollingrelease/ (only 1 per plugin!)

So tests are versioned or pinned by, either a stable release pinned version or against the git rolling release
(stable release pinned version has more importante than the git rolling release tests but they're still important)

This will require to add them to ./run-tests.sh and add new corresponding flags like:
--compatibility-plugin=PluginName --compatibility-plugin-version=1.4.5

---

When starting this skill, normally the user/me/the developer, will ask you to add feature for compatibilty with ($plugin),
if the $plugin doesnt exist in references-latest-stable, let him know and stop talking to them.

Categorize the petition and classify who's the source plugin and target plugin.
- Source Plugin: This is the plugin we're actually modifying to make it compatible with "Target Plugin" (Write & Read Permissions)
- Target Plugin: This is the plugin we aim to make compatible with Source Plugin (Read Only Permission)

In case its not clear who's the source and whos the target ask to user, explainig what is source and target plugin first.

In case it exists (the 99% of time), lets do the changes by order of priority as the following:

1. Panels+ Only Changes (Source Plugin changes only)
Check first the panels+ source code related to the request, and see if its possible to fulfill the prompt request
only by modifying Panels+, if not possible then...

2. Target Plugin Minimal Changes (Stable release modified version)
You will create a copy of the stable release of target plugin into ./references-repos/_laboratory-modified-stable/
and modify that version.. and.. (read the end of this .md file to know more)

...If with target plugin MINIMAL changes is not possible, then we...

3. Target Plugin Minimal Changes (Git Rolling Release)
Yeah, create first a branch locally and do the changes there, then build and ../ (read the end of this.md file to know more)

If we're reaching point 2. or 3., then its allowed to do combination of changes in Panels+ and Target Plugin.
but IS FAR PREFERRABLE if all changes could be made only 1 side (only panels+ OR only target plugin)
modifying BOTH plugins is the LASTT RESORT UNLESS IS REALLY NECCESARY TO DO SO.

-----

The following content doesn belong explicitly to the skill are instructions only but if you found any information
important thatt could be in the skill (like routes, folders, specific logic business), include it in the skill:

1. I need a script, which, with different flags, it will copy:

- stable release to ../
- or stable release but modified in laboratory to ../
- make the build of git rolling release version to ../ (read the followign)

Git Rolling Release
Every git project have build steps completely differente, in case they dont have an easy "build" script then
create a bash script in ./reference-repos/<pluginname>_build.sh so is easily rebuild and AI doesn't have to redescover the build
all the builds will be in a fodler inside:

(its gitignored)
references-repos/_build-artifacts/<pluginname>__v*.*.*/**(content)

then will be copied to ../, because the current cwd is  /home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin
so the plugins are in ../ , resulting in: /home/kristanlaimon/.config/koreader/plugins/
the script should be smart enough to recognize if we're not in <koreaderinstallation_dinamycallyfound>/plugins/
in that case will throw a error, t

so yeah, the script does 2 things: Building, and Integrating it to koreader, so i can test it by myself in live!
in case there are other <koreaderinstallation>/plugins/<pluginname>__(same or different version), delete the old one installed
in case there's 1 then delete that 1, in case theres 2 delete those 2. TAKE MUCH CARE WITH THIS STEP, because an error
like "deleting everything" in /plugins IS FORBIDDEN IT WILL FUCK IP EVERYTHING I'VE DONE SO FAR. TAKE REALLY CARE,
JUST RM, MAKE SAFE-GUARDS EVERYTHING, TO AVOID THESE KIND OF RM ERRORES, ITS VERY SENSIBLE

Bash only, not python

this script should work for all thre options said here (previously):
- stable release to ../
- or stable release but modified in laboratory to ../
- make the build of git rolling release version to ../ (read the followign)

