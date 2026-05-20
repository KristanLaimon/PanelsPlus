Beginner guide" how to write a plugin #9201
Closed
Closed
"Beginner guide" how to write a plugin
#9201
@k-aito
Description
k-aito
opened on Jun 11, 2022
Hello,

I start taking an interest in Koreader and trying to make a plugin.
I can get little stuff to work with, reading the code a little and trying, but I'm curious to know if there are maybe more than the developer doc. Furthermore, I have the feeling that I miss little stuff.

I don't ask for making one for me, I will continue to try and try again, but perhaps there are code that are recommended to read for a good grasp of the concept that I didn't notice until now.

Cheers

Activity
Frenzie
Frenzie commented on Jun 12, 2022
Frenzie
on Jun 12, 2022
Member
Starting from one that does something similar might be more helpful than trying to start from scratch?

pazos
pazos commented on Jun 12, 2022
pazos
on Jun 12, 2022
Member
You probably want to use a specific widget to display some info on the screen. That's what most plugins do.

I would suggest to start with the ´hello.koplugin example. Rename it and remove the condition that disables it.

The hello plugin just displays an InfoMessage but you can use any other widget. Use it as a playground to interact and learn how to use different widgets.

Other topics, like advanced settings menu for your plugin, plugin placement into menus or hooking some plugin's methods in the dispatcher/event subsystem, are covered in other plugins. You won't find any issues when you're comfortable with widgets :)

Finally the coverbrowser.koplugin is a very nice way of figuring out what are advanced uses of a plugin (beyond display its own widgets).

k-aito
k-aito commented on Jun 12, 2022
k-aito
on Jun 12, 2022
Author
Hello, thanks for the advices. I had started with the hello world but learning lua in the same time disturb me a little, maybe.

Currently, the kind of question I have is like if there are some mandatory method (the init), if the plugin object is always a widget. And the processing with the widget, but I will try again to reuse the plugin and test each widget to figure out what will match the widget I need ^^


pazos
added 
question
 
documentation
 on Jun 12, 2022
pazos
pazos commented on Jun 12, 2022
pazos
on Jun 12, 2022
Member
Currently, the kind of question I have is like if there are some mandatory method (the init), if the plugin object is always a widget.

The base object is a container, normally a WidgetContainer, sometimes an InputContainer. All containers inherit from Widget, which calls the init method of the object when it is instanciated.

So, yeah, all plugins require an init method to be useful.

And the processing with the widget container

Since your plugin inherits from a container you can instanciate any widget you want and call UIManager:show(widgetName) to display it from any method.

By default your container does nothing on init but registers entry points(via menu, dispatcher).

The hello plugin showcases two different entry points. Both do the same: show an InfoMessage with a text. One is called via a menu entry and the other with a dispatcher action (gesture/profile)

I had started with the hello world but learning lua in the same time disturb me a little, maybe.

Yeah. Take it easy. Most of us learn lua to play with the program :) .

k-aito
k-aito commented on Jun 13, 2022
k-aito
on Jun 13, 2022
Author
Thanks, I keep it open for now if it is alright. If my question can help the documentation later, it's always good ^^

Yeah. Take it easy. Most of us learn lua to play with the program :) .

I have other questions about threading, but I will first apprehend the widgets, so I will advance step by step ^^

NiLuJe
NiLuJe commented on Jun 13, 2022
NiLuJe
on Jun 13, 2022
Member
Well, threading is easy: there isn't any ;).

Frenzie
Frenzie commented on Jun 13, 2022
Frenzie
on Jun 13, 2022
Member
There are coroutines though, depending.

k-aito
k-aito commented on Jun 14, 2022
k-aito
on Jun 14, 2022
Author
I will think about it later, but I don't think it will help.

In my case, I want to use the plugin as an interface for a website, but the "issue" is that all the pictures of the website are in WebP. I could give a try to convert it manually with FFmpeg arm on my Kobo, but it is kind of slow.

I was thinking to maybe have it convert in advance or something like that but first widget playing ^^

roygbyte
roygbyte commented on Jun 15, 2022
roygbyte
on Jun 15, 2022
Contributor
I found the Lua manual to be very helpful for learning the language. And like others, looking at other plugins like helloworld.koplugin or something similar to what I'm trying to build.

k-aito
k-aito commented on Jun 25, 2022
k-aito
on Jun 25, 2022
Author
Hello everyone thanks or all the messages

By reading again @pazos message

The hello plugin showcases two different entry points. Both do the same: show an InfoMessage with a text. One is called via a menu entry and the other with a dispatcher action (gesture/profile)

It means I can only use the callback method if I'm planning to only use tapping because I have read http://koreader.rocks/doc/modules/dispatcher.html, but it feels vague to me xD

I think that the hello plugin got 2 entry point is something important to add in the comment, I first thought the dispatcher and the onHello method were mandatory.

k-aito
k-aito commented on Jun 26, 2022
k-aito
on Jun 26, 2022
Author
I will try to explain the first step I'm trying to do, maybe it will be a bit easier.

I want first use a "window" that will display multiple text that are clickable and a way to close the windows.

For that, I first thought using a FrameContainer with a ListView that will contain TextWidget.
It works globally, I didn't dig yet about make them clickable or the pagination.

The first thing that block me is the close button. I don't understand how to combine the OverlapGroup with an existent widget.
I can try to explain more (or even draw) if it can help.

Cheers

pazos
pazos commented on Jun 26, 2022
pazos
on Jun 26, 2022
Member
Hi. I'm going to close this ticket since there's nothing actionable here. Feel free to post as closed tickets are still watched.

About issues you might find: when using widgets share the code where you're using them, the specific thing that doesn't work as you expected and what you've tried (if you tried something else outside the code chunk you're pasting)

Keep in mind previous recommendations: 1) read PIL, 2) read other plugins, 3) start simple, 4) understand code blocks first and won't try to build bigger UIs until you're confortable with simple stuff.

I won't promise somebody is going to answer your questions here but you might help potential helpers by attaching the code here (if it is trivial) or attaching a link to your own github repo/fork if you're attempting something bigger.

Also keep in mind that vague questions, like here's my code: why it fails? are skipped more frequently than specific questions like: my plugin's menu doesn't get updated until I close and reopen the menu, here's the code ->. Is there a way to live update the contents of the menu?


pazos
closed this as completedon Jun 26, 2022
k-aito
k-aito commented on Jun 26, 2022
k-aito
on Jun 26, 2022
Author
I did a few testing and I think my error is a misunderstanding from the "dimen".

I stopped to try using the CloseButton, I noticed that TitleBar is doing it too, so I'm using that.
Instead of ListView that need to do pagination and stuff like that, I thought the ScrollableContainer will be easier. There I got an error related to "dimen". There I assigned "Screen" but I think already there I'm in the wrong.
With that the display is alright, but when I do a gesture for scrolling it crash with the error
/usr/lib/koreader/luajit: frontend/ui/geometry.lua:186: attempt to call method 'area' (a nil value)
stack traceback:
	frontend/ui/geometry.lua:186: in function 'notIntersectWith'
	frontend/ui/geometry.lua:203: in function 'intersectWith'
	frontend/ui/widget/container/scrollablecontainer.lua:326: in function 'propagateEvent'
	frontend/ui/widget/container/widgetcontainer.lua:113: in function 'handleEvent'
	frontend/ui/widget/container/widgetcontainer.lua:95: in function 'propagateEvent'
	frontend/ui/widget/container/widgetcontainer.lua:113: in function 'handleEvent'
	frontend/ui/widget/container/widgetcontainer.lua:95: in function 'propagateEvent'
	frontend/ui/widget/container/widgetcontainer.lua:113: in function 'handleEvent'
	frontend/ui/uimanager.lua:1136: in function 'broadcastEvent'
	frontend/device/sdl/device.lua:218: in function 'handleSdlEv'
	frontend/device/input.lua:1254: in function 'waitEvent'
	frontend/ui/uimanager.lua:1670: in function 'handleInput'
	frontend/ui/uimanager.lua:1726: in function 'run'
	./reader.lua:324: in main chunk
	[C]: at 0x55fcfe306b90
I highly think the real issue is because of my "dimen", but maybe it will help to point me which part I missed.

I add my code as gist https://gist.github.com/k-aito/4e953eefaf7ff06ee5f463845a43fe69

pazos
pazos commented on Jun 26, 2022
pazos
on Jun 26, 2022
Member
Also I forgot to mention in-module documentation, which is always up-to-date.

For instance ListView contains something like you want and documentation about the proper usage.

poire-z
poire-z commented on Jun 26, 2022
poire-z
on Jun 26, 2022
Contributor
I noticed that TitleBar is doing it too, so I'm using that.

Bravo !

There I got an error related to "dimen". There I assigned "Screen" but I think already there I'm in the wrong.

Probably. Screen is a big object abstracting your screen. It is not a Geom object (what things we name "dimen" are), and it also has no Geom object has a property.
So, you'd need to create one from the Screen size, as in:

koreader/frontend/ui/widget/keyboardlayoutdialog.lua

Lines 164 to 167 in 6e647a6

 dimen = Geom:new{ 
     w = Screen:getWidth(), 
     h = Screen:getHeight(), 
 }, 
Instead of ListView

That's a widget we rarely if ever use. I see it's only used by ui/widget/networksetting.lua.

I thought the ScrollableContainer will be easier

Probably not easier :) I think it needs a little bit of help from other widgets (its container, or its containees). It's not something that you just plug and it works :/
But it's been used recently. For what you want, you might study ui/widget/keyboardlayoutdialog.lua, it's the window you get when long-pressing on this key in the keyboard:
image

But may be, before getting frustrated by ScrollableContainer, first try to just make your list of things shown, and do the things you want to do when tapped on. Maybe a ButtonDialogTitle is all you need:

koreader/frontend/apps/cloudstorage/cloudstorage.lua

Lines 120 to 140 in 6e647a6

 function CloudStorage:selectCloudType() 
     local buttons = {} 
     for server_type, name in FFIUtil.orderedPairs(server_types) do 
         table.insert(buttons, { 
             { 
                 text = name, 
                 callback = function() 
                     UIManager:close(self.cloud_dialog) 
                     self:configCloud(server_type) 
                 end, 
             }, 
         }) 
     end 
     self.cloud_dialog = ButtonDialogTitle:new{ 
         title = _("Add new cloud storage"), 
         title_align = "center", 
         buttons = buttons, 
     } 
     UIManager:show(self.cloud_dialog) 
     return true 
 end 
image

Best to start from something that you use and looks like what you want - and learn with cut & paste and learning by trying to fix what doesn't work :)

k-aito
k-aito commented on Jun 26, 2022
k-aito
on Jun 26, 2022
Author
Thanks, it's true I will first do what I want and add the listview / scrolling later.
Thanks for the advice, I will take a look ^^


poire-z
mentioned this on Aug 16, 2023
Question related to supporting javascript #10822