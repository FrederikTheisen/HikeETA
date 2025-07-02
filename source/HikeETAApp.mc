import Toybox.Application;
import Toybox.Application.Properties;
import Toybox.Lang;
import Toybox.WatchUi;

using Toybox.Activity as Activity;
using Toybox.Position as Pos;
using Toybox.Time as Time;
using Toybox.System as Sys;
using Toybox.Math as Math;

// Class that reads settings on startup
class HikeETAApp extends Application.AppBase 
{
    function initialize() 
    {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state as Dictionary?) as Void 
    {

    }

    // onStop() is called when your application is exiting
    function onStop(state as Dictionary?) as Void 
    {
    }

    //! Return the initial view of your application here
    function getInitialView() 
    {
        return [ new HikeETAView() ];
    }
}

function getApp() as HikeETAApp 
{
    return Application.getApp() as HikeETAApp;
}