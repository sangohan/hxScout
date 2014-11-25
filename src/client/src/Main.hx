package;

import flash.display.*;
import flash.events.*;

import openfl.net.Socket;
import haxe.ds.StringMap;

class Main extends Sprite {

  private var fps:openfl.display.FPS;
  private var flm_sessions:StringMap<FLMSession> = new StringMap<FLMSession>();
  private var gui:HXScoutClientGUI;

  public function new()
  {
    super();

    setup_stage();

    function on_server_connected(s:Socket) {
      trace("Got socket: "+s);
      addChildAt(gui = new HXScoutClientGUI(), 0);
      center();
      setup_frame_data_receiver(s);
    }

    // CPP, start server thread automatically, failover to request
    #if cpp
      var listener = cpp.vm.Thread.create(Server.main);
      var s:Socket = null;
      Sys.sleep(0.2);
      s = setup_socket("localhost", 7933,
                       function() {
                         on_server_connected(s);
                       },
                       function() {
                         ui_server_request(on_server_connected);
                       });
    #else
      ui_server_request(on_server_connected);
    #end

  }

  function ui_server_request(callback)
  {
    var lbl = Util.make_label("Attach to hxScout server at: ", 17);
    var inp:Dynamic = null;
    inp = Util.make_input(200, 17, 0xaaaaaa, "localhost:7933",
                          function(hostname) {
                            var s:Socket = null;
                            function success() {
                              Util.fade_away(lbl);
                              Util.fade_away(inp.cont).then(function() {
                                inp.cont.parent.removeChild(inp.cont);
                                callback(s);
                              });
                            }
                            function err() {
                              Util.shake(inp.cont);
                            }
                            var host = hostname;
                            var port:Int = 7933;
                            if (~/:\d+$/.match(host)) {
                              host = ~/:\d+$/.replace(hostname, "");
                              port = Std.parseInt(~/.*:(\d+)/.replace(hostname, "$1"));
                            }
                            trace("Connecting to host="+host+", port="+port);
                            s = setup_socket(host, port, success, err);
                          });

    // BUG: trace(inp.cont.width);  returns null in neko

    lbl.x = -(lbl.width + inp.bug)/2;
    lbl.y = -lbl.height/2;
    inp.cont.x = lbl.x + lbl.width;
    inp.cont.y = lbl.y;
    addChild(lbl);
    addChild(inp.cont);
  }

  function center(e=null) {
    this.x = stage.stageWidth/2;
    this.y = stage.stageHeight/2;
    fps.x = -this.x;
    fps.y = -this.y;
    if (gui!=null) gui.resize(stage.stageWidth, stage.stageHeight);
  }

  function setup_stage()
  {
    fps = new openfl.display.FPS(0,0,0xffffff);
    addChild(fps);
    center();
    stage.addEventListener(flash.events.Event.RESIZE, center);
  }

  function setup_socket(host, port, on_success, on_cannot_connect)
  {
    var s = new Socket();

    var cleanup = null;

    function error(e) {
      trace("Error, connect failed!");
      cleanup();
      on_cannot_connect();
    }
    function connect(e) {
      trace("Socket connect succeeded!");
      cleanup();
      on_success();
    }

    cleanup = function() {
      s.removeEventListener(IOErrorEvent.IO_ERROR, error);
      s.removeEventListener(Event.CONNECT, connect);
    }

    s.addEventListener(IOErrorEvent.IO_ERROR, error);
    s.addEventListener(Event.CONNECT, connect);
    s.connect(host, port);

    return s;
  }

  function setup_frame_data_receiver(server:Socket) {
    var frame_data_length:UInt = 0;

    // Probably not necessary, meh
    var keepalive = GlobalTimer.setInterval(function() {
      server.writeInt(0); // FYI, sends 4 bytes
    }, 2000);

    function on_enter_frame(e:Event) {
      while (true) { // process multiple frame_data's per client frame
        server.endian = openfl.utils.Endian.LITTLE_ENDIAN;
        if (server.bytesAvailable>4 && frame_data_length==0) {
          frame_data_length = server.readInt();
        }
        if (server.bytesAvailable>=frame_data_length && frame_data_length>0) {
          var frame_data = haxe.Json.parse(server.readUTFBytes(frame_data_length));
          frame_data_length = 0;
          //trace(frame_data);
          var inst_id:String = frame_data.inst_id;
          if (!flm_sessions.exists(inst_id)) {
            flm_sessions.set(inst_id, new FLMSession(inst_id));
            gui.add_session(flm_sessions.get(inst_id));
          }
          flm_sessions.get(inst_id).receive_frame_data(frame_data);
          if (frame_data.session_name!=null) {
            gui.update_name(frame_data.session_name, frame_data.inst_id);
          }
        } else {
          break;
        }
      }
    }

    stage.addEventListener(Event.ENTER_FRAME, on_enter_frame);
  }

}

class FLMSession {

  public var frames:Array<Dynamic> = [];
  public var inst_id:String;
  public var temp_mem:StringMap<Int>;
  public var name:String;
  public var stack_strings:Array<String> = ["1-indexed"];

  public function new(iid:String)
  {
    inst_id = iid;
    name = inst_id;
  }

  public function receive_frame_data(frame_data)
  {
    if (frame_data.session_name!=null) {
      name = frame_data.session_name;
    } else {
      if (frame_data.push_stack_strings!=null) {
        var strings:Array<String> = frame_data.push_stack_strings;
        for (str in strings) {
          stack_strings.push(str);
        }
      }
      //if (frame_data.samples!=null) {
      //  trace(haxe.Json.stringify(frame_data.samples, null, "  "));
      //}
      frames.push(frame_data);
    }
  }

}

class HXScoutClientGUI extends Sprite
{
  private var sessions = [];

  private var nav_pane:Pane;
  private var summary_pane:Pane;
  private var timing_pane:Pane;
  private var memory_pane:Pane;
  private var session_pane:Pane;
  private var detail_pane:Pane;

  private var active_session = -1;
  private var last_frame_drawn = -1;

  private var nav_ctrl:NavController;

  public function new()
  {
    super();

    nav_pane = new Pane();
    summary_pane = new Pane();
    timing_pane = new Pane(true);
    memory_pane = new Pane(true);
    session_pane = new Pane();
    detail_pane = new Pane();

    addChild(nav_pane);
    addChild(summary_pane);
    addChild(timing_pane);
    addChild(memory_pane);
    addChild(session_pane);
    addChild(detail_pane);

    nav_ctrl = new NavController(nav_pane, timing_pane, memory_pane);
    //AEL.add(timing_pane, MouseEvent.MOUSE_DOWN, handle_select_start);

    addEventListener(Event.ENTER_FRAME, on_enter_frame);
  }

  private var layout = {
    nav:{
      height:50,
    },
    timing:{
      height:150,
      scale:300
    },
    session:{
      width:200,
    },
    summary:{
      width:300,
    },
    frame_width:6,
    MSCALE:100
  }

  public function resize(w:Float=0, h:Float=0)
  {
    var y = 0;
    resize_pane(w, h, session_pane, 0,       0, (layout.session.width),   h);
    resize_pane(w, h, nav_pane,     layout.session.width, y, w-(layout.session.width), layout.nav.height);
    y += layout.nav.height;
    resize_pane(w, h, timing_pane,  layout.session.width, y, w-(layout.session.width+layout.summary.width), layout.timing.height);
    resize_pane(w, h, summary_pane, w-layout.summary.width, y, layout.summary.width, layout.timing.height*2);
    y += layout.timing.height;
    resize_pane(w, h, memory_pane,  layout.session.width, y, w-(layout.session.width+layout.summary.width), layout.timing.height);
    y += layout.timing.height;
    resize_pane(w, h, detail_pane,  layout.session.width, y, w-(layout.session.width), h-y);
  }

  inline function resize_pane(stage_w:Float, stage_h:Float, pane:Sprite, x:Float, y:Float, w:Float, h:Float)
  {
    pane.width = w;
    pane.height = h;
    pane.x = -stage_w/2 + x;
    pane.y = -stage_h/2 + y;
  }

  public function update_name(name:String, inst_id:String)
  {
    trace("Set name: "+inst_id+", "+name);
    var lbl = Util.make_label(name, 15);
    lbl.filters = [new flash.filters.DropShadowFilter(1, 120, 0x0, 0.8, 3, 3, 1, 2)];
    var ses:Sprite = cast(session_pane.cont.getChildAt(Std.parseInt(inst_id)));
    lbl.y = ses.height/2-lbl.height/2;
    lbl.x = 4;
    ses.addChild(lbl);
  }

  public function add_session(flm_session:FLMSession)
  {
    trace("GUI got new session: "+flm_session.inst_id);
    sessions.push(flm_session);
    if (active_session<0) {
      set_active_session(sessions.length-1);
    }

    var s:Sprite = new Sprite();
    var m:flash.geom.Matrix = new flash.geom.Matrix();
    m.createGradientBox(session_pane.innerWidth,42,Math.PI/180*(-90));
    s.graphics.beginGradientFill(openfl.display.GradientType.LINEAR,
                                 [0x444444, 0x535353],
                                 [1, 1],
                                 [0,255],
                                 m);
    s.graphics.lineStyle(2, 0x555555);
    s.graphics.drawRect(0,0,session_pane.innerWidth,42);
    s.buttonMode = true;
    AEL.add(s, MouseEvent.CLICK, function(e) { set_active_session(s.parent.getChildIndex(s)); });
    s.y = (sessions.length-1)*46;
    session_pane.cont.addChild(s);
  }

  public function set_active_session(n:Int)
  {
    if (n>=sessions.length) return;
    active_session = n;
    last_frame_drawn = -1;
    while (timing_pane.cont.numChildren>0) timing_pane.cont.removeChildAt(0);
    while (memory_pane.cont.numChildren>0) memory_pane.cont.removeChildAt(0);

    var session:FLMSession = sessions[active_session];
    session.temp_mem = new StringMap<Int>();

    reset_nav_pane();
    resize(stage.stageWidth, stage.stageHeight);
  }

  function reset_nav_pane()
  {
    // dispose?
    while (nav_pane.cont.numChildren>0) nav_pane.cont.removeChildAt(0);
    nav_pane.cont.addChild(new Bitmap(new BitmapData(Std.int(nav_pane.innerWidth), Std.int(nav_pane.innerHeight), true, 0x0)));
  }

  var mem_types = ["used","telemetry.overhead","managed.used","managed","total"];

  private function on_enter_frame(e:Event)
  {
    if (active_session<0) return;
    var i=0;
    var session:FLMSession = sessions[active_session];
    for (i in (last_frame_drawn+1)...session.frames.length) {
      var frame = session.frames[i];

      if (Reflect.hasField(frame, "mem")) {
        for (key in mem_types) {
          if (Reflect.hasField(frame.mem, key)) {
            session.temp_mem.set(key, Reflect.field(frame.mem, key));
          }
        }
      }

      //trace(" -- Drawing ["+session.inst_id+"]:"+frame.id);
      //trace(frame);

      add_rect(i, timing_pane, frame.duration.total/layout.timing.scale, 0x444444, false);
      add_rect(i, timing_pane, frame.duration.gc/layout.timing.scale, 0xdd5522, true);
      add_rect(i, timing_pane, frame.duration.other/layout.timing.scale, 0xaa4488, true);
      add_rect(i, timing_pane, frame.duration.as/layout.timing.scale, 0x2288cc, true);
      add_rect(i, timing_pane, frame.duration.rend/layout.timing.scale, 0x66aa66, true);

      if (!session.temp_mem.exists("total")) continue;

      //trace(session.temp_mem);

      add_rect(i, memory_pane, session.temp_mem.get("total")/layout.MSCALE, 0x444444, false);
      add_rect(i, memory_pane, session.temp_mem.get("managed.used")/layout.MSCALE, 0x227788, true);
      add_rect(i, memory_pane, session.temp_mem.get("bitmap.display")/layout.MSCALE, 0x22aa99, true);

      //var s:Shape = new Shape();
      //s.graphics.beginFill(0x444444);
      //s.graphics.drawRect(0,0,layout.frame_width-1,session.temp_mem.get("total")/500);
      //s.x = Std.parseInt(frame.id)*layout.frame_width;
      //s.y = -s.height;
      //memory_pane.cont.addChild(s);

    }
    last_frame_drawn = session.frames.length-1;
  }

  private var stack_y:Float = 0;
  private inline function add_rect(id:Int, pane:Pane, value:Float, color:Int, stack:Bool) {
    if (!stack) stack_y = 0;
    var s:Shape = new Shape();
    s.graphics.beginFill(color);
    s.graphics.drawRect(0,0,layout.frame_width-1,value);
    s.x = id*layout.frame_width;
    s.y = -s.height-stack_y;
    pane.cont.addChild(s);
    if (stack) stack_y += s.height;

    if (pane==timing_pane) {
      var m = new flash.geom.Matrix();
      m.translate(s.x, 0);
      var sc:Float = nav_pane.innerHeight/timing_pane.innerHeight;
      m.scale(1/layout.frame_width, -sc);
      m.translate(0, nav_pane.innerHeight);
      cast(nav_pane.cont.getChildAt(0)).bitmapData.draw(s, m, null, openfl.display.BlendMode.ADD);
    }
  }
}

class NavController {
  private var nav_pane:Pane;
  private var timing_pane:Pane;
  private var memory_pane:Pane;

  public function new (nav, timing, memory):Void
  {
    nav_pane = nav;
    timing_pane = timing;
    memory_pane = memory;

    AEL.add(nav_pane, MouseEvent.MOUSE_DOWN, handle_nav_start);
  }

  function handle_nav_start(e:Event)
  {
    nav_pane.stage.addEventListener(MouseEvent.MOUSE_MOVE, handle_nav_move);
    nav_pane.stage.addEventListener(MouseEvent.MOUSE_UP, handle_nav_stop);

    nav_to(nav_pane.mouseX);
  }

  function handle_nav_stop(e:Event)
  {
    nav_pane.stage.removeEventListener(MouseEvent.MOUSE_MOVE, handle_nav_move);
    nav_pane.stage.removeEventListener(MouseEvent.MOUSE_UP, handle_nav_stop);
  }

  function handle_nav_move(e:Event)
  {
    nav_to(nav_pane.mouseX);
  }

  function nav_to(x:Float)
  {
    //trace("Nav to: "+x);
    timing_pane.cont.scrollRect.x = -x;

    var r = new flash.geom.Rectangle();
    r.copyFrom(timing_pane.cont.scrollRect);
    r.x = x*6; // layout.frame_width
    timing_pane.cont.scrollRect = r;
    memory_pane.cont.scrollRect = r;
  }
}

class Pane extends Sprite {

  public static inline var PAD:Float = 6;

  public var cont(default, null):Sprite;
  var decor:Shape;

  var _width:Float;
  var _height:Float;
  var _bottom_aligned:Bool;

  public function new (bottom_aligned:Bool=false, w:Float=0, h:Float=0)
  {
    super();
    _bottom_aligned = bottom_aligned;
    _width = w;
    _height = h;

    decor = new Shape();
    super.addChild(decor);

    cont = new Sprite();
    super.addChild(cont);
    cont.scrollRect = new flash.geom.Rectangle(0,_bottom_aligned?-h:h,w,h);
    cont.x = cont.y = PAD;

    redraw();
  }

  override public function set_width(w:Float):Float { _width = w; redraw(); return w; }
  override public function get_width():Float { return _width; }
  override public function set_height(h:Float):Float { _height = h; redraw(); return h; }
  override public function get_height():Float { return _height; }

  public var innerWidth(get, null):Float;
  public var innerHeight(get, null):Float;
  public function get_innerWidth():Float { return _width-2*PAD; }
  public function get_innerHeight():Float { return _height-2*PAD; }

  static var TEMP_M:flash.geom.Matrix = new flash.geom.Matrix();

  private function redraw()
  {
    cont.scrollRect = new flash.geom.Rectangle(cont.scrollRect.x,
                                               _bottom_aligned ? -(_height-2*PAD) : 0,
                                               _width-2*PAD,
                                               _height-2*PAD);

    decor.graphics.clear();
    decor.graphics.lineStyle(3, 0x111111);

    TEMP_M.identity();
    TEMP_M.createGradientBox(_width,_height,Math.PI/180*(-90));
    decor.graphics.beginGradientFill(openfl.display.GradientType.LINEAR,
                                     [0x444444, 0x535353],
                                     [1, 1],
                                     [0,255],
                                     TEMP_M);

    decor.graphics.drawRoundRect(0,0,_width,_height, 7);

    // cont knockout
    var p:Float = PAD/2;
    decor.graphics.lineStyle(0,0, 0);
    decor.graphics.beginFill(0x000000, 0.25);
    decor.graphics.drawRoundRect(p,p,_width-p*2,_height-p*2,5);

  }
}
