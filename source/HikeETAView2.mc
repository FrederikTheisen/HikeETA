import Toybox.Activity;
import Toybox.Application;
import Toybox.Application.Properties;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Math;
import Toybox.Time;

using Toybox.System as Sys;
using Toybox.Time.Gregorian;

class HikeETAView extends WatchUi.DataField 
{
    // Constants
    const TIME_SAMPLE_BUFFER_MAX_LENGTH = 200;
    const BASE_FLAT_SPEED = 0.7; // 2.5 km/t
    const EWMA_ROBUST_ALPHA = 0.1;
    const SPEED_SAMPLE_WINDOW_SIZE = 2; 

    enum { LAYOUT_FULL, LAYOUT_HALF_TOP, LAYOUT_HALF_BOTTOM, LAYOUT_QUARTER_UPPER, LAYOUT_QUARTER_LOWER_RIGHT, LAYOUT_QUARTER_LOWER_LEFT, LAYOUT_WIDE, LAYOUT_SMALL, LAYOUT_DOME_TOP, LAYOUT_DOME_BOTTOM, LAYOUT_DOME_TOP_NARROW, LAYOUT_DOME_BOTTOM_NARROW }

    // Settings
    var _timeSampleInterval as Float = 5.0;
    var _timeSampleIntervalTarget as Number = 20;
    var _layout as Number = 0;

    // Rolling buffer for time samples
    var _timeSamples as Array<Dictionary>;
    var _oldestSampleIdx as Number = 0;
    var _timeCount as Number = 0;

    var _lastTimeSample as Float = 0.0;

    // Speed samples
    var _mostRecentSpeedSample as Dictionary or Null = null;

    // Distance and elevation
    var _hasDestination as Boolean = false;
    var _distanceToDestination as Float or Null = null;
    var _offCourse as Boolean = true;
    var _remainingDistance as Float = -1.0;

    //var _currentAltitude as Float or Null = null;
    //var _destinationAltitude as Float or Null = null;

    var _elapsedDistance as Float = 0.0;

    // Calculated speeds
    var _estimatedRobustSpeed as Float = 0.0;
    var _actualWindowSpeed as Float = BASE_FLAT_SPEED;

    var _hasEwmaSpeed as Boolean = false;
    var _hasWindowSpeed as Boolean = false;

    // Calculated times remaining
    var _timeRemaining as Time.Duration or Null = null;

    // Calculated ETAs
    var _eta as Time.Moment or Null = null;

    var _infoOneHourWindowLength as Float = 300.0;
    var _infoOneHour as Dictionary or Null = null;

    function getMomentString(moment as Time.Moment or Null) as String {
        if (moment == null)
        {
            return "--:--";
        }
        var gm = Gregorian.info(moment as Time.Moment, Time.FORMAT_MEDIUM);
        return Lang.format("$1$:$2$", [gm.hour.format("%02d"), gm.min.format("%02d")]);
    }

    function getPaceStringFromSpeed(speed as Float) as String {
        if (speed == 0) { return "---"; }

        var pace = 16.67 / speed; // min/km
        var min = Math.floor(pace);
        var sec = (pace - min) * 60;
       
        return (min.format("%d") + ":" + sec.format("%02d"));
    }

    function getDurationString(duration as Time.Duration) as String {
        if (duration == null) { return "---"; }
        var remain = duration.value() as Number;
        var hh = Math.floor(remain / 3600.0);
        var mm = Math.floor((remain - hh * 3600.0) / 60.0);

        if (hh < 1) { return mm.format("%d") + "m"; }
        else { return hh.format("%d") + "h " + mm.format("%d") + "m"; }
    }

    function currentTime(info as Activity.Info) as Float {
        if (info.elapsedTime != null) { return (info.elapsedTime as Number) / 1000.0; }
        else { return 0.0; }
    }

    // Total distance based on elapsed + remaining
    function getTotalDistance() as Float {
        return (_elapsedDistance + _remainingDistance);
    }

    function hasSpeed() as Boolean {
        return (_hasEwmaSpeed || _hasWindowSpeed);
    }

    function isHalfway() as Boolean {
        if (_hasDestination) { return (_elapsedDistance > _remainingDistance); }
        else { return false; }
    }

    function getCurrentGrade() as Float {
        if (_mostRecentSpeedSample == null) { return 0.0; }

        return _mostRecentSpeedSample["grade"];
    }

    function getRemainingGrade(info as Activity.Info) as Float {
        if (info has :elevationAtDestination && info.elevationAtDestination != null) {
            var dElev = info.elevationAtDestination - info.altitude;
            var dDist = info.distanceToDestination;

            if (dElev != null || dDist != null)
            {
                if (dDist >= 4) { return (dElev / dDist) as Float; } 
            }
        }
        return 0.0;
    }

    function updateDistancesInfo(info as Activity.Info) as Void {
        var dist = null; // TODO check if has distance to destination and other things
        var offCourseDist = null;
        
        _hasDestination = false;

        if (info has :distanceToDestination && info.distanceToDestination != null) {
            dist = info.distanceToDestination;

            if (dist != null && dist > 0) {
                _distanceToDestination = dist as Float;
                
                _offCourse = false;
                _hasDestination = true;
                
                _remainingDistance = _distanceToDestination;
            }
        }

        if (info has :offCourseDistance && info.offCourseDistance != null) {
            offCourseDist = info.offCourseDistance;

            if (_hasDestination && offCourseDist > 0) {
                _offCourse = true;
                _hasDestination = true;
                
                _remainingDistance = _distanceToDestination + offCourseDist;
            }
        }

        if (!_hasDestination) {
            _remainingDistance = -1.0; // No distance information available
        }

        if (info has :elapsedDistance && info.elapsedDistance != null) { _elapsedDistance = info.elapsedDistance; }
    }

    function initialize() {
        DataField.initialize();
        _timeSamples = new Array<Dictionary>[TIME_SAMPLE_BUFFER_MAX_LENGTH];
        _oldestSampleIdx = 0;
        _timeCount = 0;
        _lastTimeSample = 0.0;
    }

    // Layout overridden; drawing will be done in onUpdate dynamically
    function onLayout(dc as Dc) as Void  {
        var layout = determineDataFieldLayout(dc);

        if (layout == LAYOUT_FULL) { View.setLayout(Rez.Layouts.FullScreenLayout(dc)); }
        else if (layout == LAYOUT_HALF_TOP) { View.setLayout(Rez.Layouts.TopHalfLayout(dc)); }
        else if (layout == LAYOUT_HALF_BOTTOM) { View.setLayout(Rez.Layouts.BottomHalfLayout(dc)); }
        else if (layout == LAYOUT_DOME_TOP) { View.setLayout(Rez.Layouts.DomeTopLayout(dc)); }
        else if (layout == LAYOUT_WIDE) { View.setLayout(Rez.Layouts.WideLayout(dc)); }
        else if (layout == LAYOUT_DOME_TOP_NARROW) { View.setLayout(Rez.Layouts.DomeTopNarrow(dc)); }
        else if (layout == LAYOUT_DOME_BOTTOM_NARROW) { View.setLayout(Rez.Layouts.DomeBottomNarrow(dc)); }
        else if (layout == LAYOUT_QUARTER_UPPER)  { View.setLayout(Rez.Layouts.QuarterUpperLayout(dc)); }
        else if (layout == LAYOUT_QUARTER_LOWER_LEFT)  { View.setLayout(Rez.Layouts.QuarterLowLeftLayout(dc)); }
        else if (layout == LAYOUT_QUARTER_LOWER_RIGHT)  { View.setLayout(Rez.Layouts.QuarterLowRightLayout(dc)); }
        else { View.setLayout(Rez.Layouts.SimpleLayout(dc)); }

        _layout = layout;
    }

    function determineDataFieldLayout(dc as Dc) as Number {
        var height_view = dc.getHeight();
        var width_view = dc.getWidth();
        var height_device = System.getDeviceSettings().screenHeight;
        var width_device = System.getDeviceSettings().screenWidth;
        var obscurityFlags = DataField.getObscurityFlags();

        if (height_view == height_device) { return LAYOUT_FULL; } // Only full screen has full height
        else if ((height_view - height_device / 2).abs() < 5) {
            //Half screen or quarter views?
            if (width_view == width_device) {
                if (obscurityFlags == (OBSCURE_TOP | OBSCURE_LEFT | OBSCURE_RIGHT)) { return LAYOUT_HALF_TOP; }
                else { return LAYOUT_HALF_BOTTOM; }
            }
            else {
                if (obscurityFlags == (OBSCURE_BOTTOM | OBSCURE_LEFT)) { return LAYOUT_QUARTER_LOWER_LEFT; }
                else if (obscurityFlags == (OBSCURE_BOTTOM | OBSCURE_RIGHT)) { return LAYOUT_QUARTER_LOWER_RIGHT; }
                else { return LAYOUT_QUARTER_UPPER; }
            }
        }
        else if ((height_view - height_device/3).abs() <= 10) {
            //Larger dome views
            if (obscurityFlags == (OBSCURE_TOP | OBSCURE_LEFT | OBSCURE_RIGHT)) { return LAYOUT_DOME_TOP; }
            else if (obscurityFlags == (OBSCURE_BOTTOM | OBSCURE_LEFT | OBSCURE_RIGHT)) { return LAYOUT_DOME_BOTTOM; }
            else if (width_view == width_device) { return LAYOUT_WIDE; }
            else { return LAYOUT_SMALL; }
        }
        else if ((height_view - height_device/4).abs() <= 5) {
            // Some dome views have this height
            if (obscurityFlags == (OBSCURE_TOP | OBSCURE_LEFT | OBSCURE_RIGHT)) { return LAYOUT_DOME_TOP_NARROW; }
            else if (obscurityFlags == (OBSCURE_BOTTOM | OBSCURE_LEFT | OBSCURE_RIGHT)) { return LAYOUT_DOME_BOTTOM_NARROW; }
        }
        else if ((height_view - height_device/6).abs() <= 5 && width_view == width_device) {
            // Some dome views have this height, but they are quite small
            if (obscurityFlags == (OBSCURE_TOP | OBSCURE_LEFT | OBSCURE_RIGHT)) { return LAYOUT_SMALL; }
            else if (obscurityFlags == (OBSCURE_BOTTOM | OBSCURE_LEFT | OBSCURE_RIGHT)) { return LAYOUT_SMALL; }
        }

        if (width_view == width_device) { return LAYOUT_WIDE; } 

        return LAYOUT_SMALL;
    }

    function compute(info as Activity.Info) as Void  {
        var dist = info.elapsedDistance;
        
        updateDistancesInfo(info);

        // Store current/destination altitude and distance remaining
        //if (info.altitude != null) { _currentAltitude = info.altitude as Float; }
        //if (info.elevationAtDestination != null) { _destinationAltitude = info.elevationAtDestination as Float; }

        if (dist == null) { return; }

        if (updateSampleData(info))
        {
            updateSpeedSamples();

            _estimatedRobustSpeed = _computeEWMASpeed(info, _estimatedRobustSpeed, EWMA_ROBUST_ALPHA);
            _actualWindowSpeed = _computeSpeedForWindow(3600.0);

            _infoOneHour = _computeInfoForWindow(_infoOneHourWindowLength);

            computeRemainingTime(info);

            if (_infoOneHourWindowLength < 3600.0) {
                _infoOneHourWindowLength += _timeSampleInterval * 0.5;
            }

            var __ete = "-";
            if (_timeRemaining != null) { __ete = _timeRemaining.value().format("%d"); }

            // Sys.println(currentTime(info).format("%d") + " " + 
            //     dist.format("%d") + " " + 
            //     _estimatedRobustSpeed.format("%.3f") + " " +
            //     _actualWindowSpeed.format("%.3f") + " " +
            //     __ete);
        }
    }

    function updateSampleData(info as Activity.Info) as Boolean {
        var now = currentTime(info);

        if (now - _lastTimeSample < _timeSampleInterval) { return false; }
        
        var timeBufLen = _timeSamples.size();
        var currIdx = (_oldestSampleIdx + _timeCount) % timeBufLen;
        _timeSamples[currIdx] = { "time" => now, "elapsedDist" => _elapsedDistance, "altitude" => info.altitude };
        if (_timeCount < timeBufLen) { _timeCount += 1; }
        else { _oldestSampleIdx = (_oldestSampleIdx + 1) % timeBufLen; }
        _lastTimeSample = now;
        
        if (_timeSampleInterval < _timeSampleIntervalTarget) { _timeSampleInterval += 0.3; }

        System.println(now.format("%d") + " " + 
            _elapsedDistance.format("%d") + " " + 
            info.altitude.format("%.3f"));

        return true;
    }

    function updateSpeedSamples() as Void {
        if (_timeCount > SPEED_SAMPLE_WINDOW_SIZE) {
            var timeBufLen = _timeSamples.size();
            var currIdx = (_oldestSampleIdx + _timeCount - 1) % timeBufLen;
            var prevIdx = (currIdx - SPEED_SAMPLE_WINDOW_SIZE + timeBufLen) % timeBufLen;
            var currSample = _timeSamples[currIdx];
            var prevSample = _timeSamples[prevIdx];

            if (currSample == null || prevSample == null) { return; }

            var dt = currSample["time"] - prevSample["time"];
            var dd = currSample["elapsedDist"] - prevSample["elapsedDist"];
            var de = currSample["altitude"] - prevSample["altitude"];
            
            // Protect against edge cases
            var grade = 0.0 as Float;
            if (dd > 1) { grade = de / dd as Float; } 

            var speed = 0.0 as Float;
            if (dt > 1) { speed = (dd / dt) as Float; }

            if (speed > 4) { speed = 4.0; }

            _mostRecentSpeedSample = { "speed" => speed, "deltaDist" => dd, "grade" => grade };
        }
    }

    function _computeSpeedForWindow(windowSec as Float) as Float {
        _hasWindowSpeed = false;

        if (_timeCount < 2) { return -1.0; }
        var bufLen = _timeSamples.size();
        var newestIdx = (_oldestSampleIdx + _timeCount - 1) % bufLen;
        var newest = _timeSamples[newestIdx];
        var newestTime = newest["time"];
        var cutoff = newestTime - windowSec;
        var oldestTime = 0.0;
        var oldestSample = {};
        for (var i = 0; i < _timeCount; i += 1) {
            var idx = (_oldestSampleIdx + i) % bufLen;
            var sample = _timeSamples[idx];
            if (sample["time"] >= cutoff) {
                oldestSample = sample;
                oldestTime = sample["time"];
                break;
            }
        }
        if (oldestSample == null) { return -1.0; }
        var dt = newestTime - oldestTime;
        if (dt <= 0) { return 0.0; }
        var dd = newest["elapsedDist"] - oldestSample["elapsedDist"];

        _hasWindowSpeed = true;

        return (dd / dt) as Float;
    }

    function _computeInfoForWindow(windowSec as Float) as Dictionary or Null {
        if (_timeCount < 2) { return null; }
        var bufLen = _timeSamples.size();
        var newestIdx = (_oldestSampleIdx + _timeCount - 1) % bufLen;
        var newest = _timeSamples[newestIdx];
        var newestTime = newest["time"];
        var cutoff = newestTime - windowSec;
        var oldestTime = 0.0;
        var oldestSample = {};
        for (var i = 0; i < _timeCount; i += 1) {
            var idx = (_oldestSampleIdx + i) % bufLen;
            var sample = _timeSamples[idx];
            if (sample["time"] >= cutoff) {
                oldestSample = sample;
                oldestTime = sample["time"];
                break;
            }
        }
        if (oldestSample == null) { return null; }
        var dt = newestTime - oldestTime;
        if (dt <= 0) { return null; }
        var dd = newest["elapsedDist"] - oldestSample["elapsedDist"];

        var de = newest["altitude"] - oldestSample["altitude"];

        return { "delta_distance" => dd, "delta_time" => new Time.Duration(dt as Number), "delta_altitude" => de, "speed" => (dd / dt) as Float };
    }

    function _computeEWMASpeed(info as Activity.Info, speed as Float, alpha as Float) as Float {
        _hasEwmaSpeed = false;

        if (_mostRecentSpeedSample == null) { return _actualWindowSpeed; }
        if (currentTime(info) < 450) { return _actualWindowSpeed; }

        var weight_dist = _mostRecentSpeedSample["deltaDist"] / (2 + _mostRecentSpeedSample["deltaDist"]);

        alpha *= weight_dist;

        if (isHalfway()) {
            // If we are halfway, lower impact of unexpected grades
            var grad_remain = getRemainingGrade(info);
            var grad_diff = (_mostRecentSpeedSample["grade"] - grad_remain).abs();
            var weight_grade = 1 / (1 + Math.sqrt(grad_diff));
            alpha *= weight_grade;
        }

        _hasEwmaSpeed = true;

        var newSpeed = _mostRecentSpeedSample["speed"] * alpha + (1 - alpha) * speed;
        
        return newSpeed as Float;
    }

    function computeRemainingTime(info as Activity.Info) as Void {
        if (!_hasEwmaSpeed) {
            _estimatedRobustSpeed = _computeSpeedForWindow(600.0);
        }

        if (_remainingDistance > 0) {
            _timeRemaining = calculateETE(_remainingDistance, _estimatedRobustSpeed);
            _eta = calculateETA(_timeRemaining);
        }       
    }

    function calculateETE(remDist as Float, speed as Float) as Time.Duration or Null {
        if (speed <= 0) { return null; }
        return new Time.Duration((remDist / speed) as Number);
    }

    function calculateETA(ete as Time.Duration or Null) as Time.Moment or Null {
        if (ete == null) { return null; }
        return Time.now().add(ete);
    }

    function onUpdate(dc as Dc) as Void 
    {
        drawDefaultView(dc);

        // TODO: Determine if this label is visible for view first
        drawExtendedDataView(dc);

        // TODO: Determine if this label is visible for view first
        if (_layout != LAYOUT_SMALL) { drawRemainingInfo(dc); }
        if (_layout == LAYOUT_FULL) { drawOneHourWindowInfo(dc); }
        
        View.onUpdate(dc);
    }

    function drawDefaultView(dc as Dc) as Void {
        var background = View.findDrawableById("Background") as Text;
        background.setColor(getBackgroundColor());

        // Set text color
        var textColor = Graphics.COLOR_WHITE;
        if (getBackgroundColor() == Graphics.COLOR_WHITE) { textColor = Graphics.COLOR_BLACK; } 

        var value_eta = View.findDrawableById("value_eta") as Text;
        var value_pace = View.findDrawableById("value_pace") as Text;
        
        var timeStr = "--:--";

        if (_hasDestination) { timeStr = getMomentString(_eta); }

        value_eta.setColor(textColor);
        value_eta.setText(timeStr);

        if (value_pace != null)
        {
            var paceStr = "NoPaceInfo";
            if (hasSpeed() && _estimatedRobustSpeed > 0) { paceStr = getPaceStringFromSpeed(_estimatedRobustSpeed) + " /km"; }
            
            value_pace.setColor(textColor);
            value_pace.setText(paceStr);
        }
    }

    function drawExtendedDataView(dc as Dc) as Void {
        var info = Activity.getActivityInfo();
        var textColor = Graphics.COLOR_WHITE;
        if (getBackgroundColor() == Graphics.COLOR_WHITE) { textColor = Graphics.COLOR_BLACK; } 

        var value_ete = View.findDrawableById("value_ete") as Text;
        var value_grade_remaining = View.findDrawableById("value_grade_remaining") as Text;
        var value_pace_1h = View.findDrawableById("value_pace_1h") as Text;
        var value_dist_remaining = View.findDrawableById("value_dist_remaining") as Text;
        var value_pace_grade = View.findDrawableById("value_pace_grade") as Text;

        if (value_grade_remaining != null)
        {
            var grdStr = (100*getRemainingGrade(info)).format("%.1f") + "%";

            value_grade_remaining.setColor(textColor);
            value_grade_remaining.setText(grdStr);
        }

        if (value_dist_remaining != null)
        {
            var str = (_remainingDistance / 1000).format("%.1f") + " km";

            value_dist_remaining.setColor(textColor);
            value_dist_remaining.setText(str);
        }

        if (!hasSpeed()) { return; }

        if (value_ete != null)
        {
            var eteStr = getDurationString(_timeRemaining);

            value_ete.setColor(textColor);
            value_ete.setText(eteStr);
        }

        if (value_pace_1h != null)
        {
            var str = getPaceStringFromSpeed(_actualWindowSpeed);

            value_pace_1h.setColor(textColor);
            value_pace_1h.setText(str + " (1h pace)");
        }

        if (value_pace_grade != null)
        {
            var str = getPaceStringFromSpeed(_estimatedRobustSpeed) + " /km | " + (100*getCurrentGrade()).format("%.1f") + "%";

            value_pace_grade.setColor(textColor);
            value_pace_grade.setText(str);
        }
    }

    function drawRemainingInfo(ds as Dc) as Void {
        if (!_hasDestination || !hasSpeed()) { return; }
        var value_remaining_info = View.findDrawableById("value_remaining_info") as Text;

        if (value_remaining_info == null) { return; }

        // Get text color
        var textColor = Graphics.COLOR_WHITE;
        if (getBackgroundColor() == Graphics.COLOR_WHITE) { textColor = Graphics.COLOR_BLACK; }

        var str = "No Path Info";

        if (!_hasDestination) { str = "No Dest. Info"; }
        else {
            // Try do draw distance | grade | time
            var info = Activity.getActivityInfo();
            str = (_remainingDistance / 1000).format("%.1f") + "km|";
            str += (100*getRemainingGrade(info)).format("%.1f") + "%|";
            str += getDurationString(_timeRemaining);
        }

        value_remaining_info.setColor(textColor);
        value_remaining_info.setText(str);

    }

    function drawOneHourWindowInfo(dc as Dc) as Void {
        var value_max_window_info = View.findDrawableById("value_max_window_info") as Text;
        var label_max_window_info = View.findDrawableById("label_recent") as Text;

        var textColor = Graphics.COLOR_WHITE;
        if (getBackgroundColor() == Graphics.COLOR_WHITE) { textColor = Graphics.COLOR_BLACK; } 

        if (value_max_window_info != null) {
            if (_infoOneHour != null) {
                var str = _infoOneHour["delta_distance"].format("%d") + "m|";
                str += _infoOneHour["delta_altitude"].format("%d") + "m|";
                str += getPaceStringFromSpeed(_infoOneHour["speed"]) + "/km";
                value_max_window_info.setText(str);
                value_max_window_info.setColor(textColor);
            }
        }

        if (label_max_window_info != null) {
            if (_infoOneHour != null) {

                var minutes = _infoOneHour["delta_time"].value() / 60.0;
                var str = "";

                if (_timeCount < TIME_SAMPLE_BUFFER_MAX_LENGTH && minutes < 5) { str = "SINCE START"; }
                else {
                    if (minutes > 50) {
                        str = "LAST HOUR INFO";
                    }
                    else {
                        var _5min = Math.floor(minutes / 5.0);

                        str = "LAST " + (_5min*5).format("%d") + " MIN INFO";
                    }
                }

                label_max_window_info.setText(str);
                //label_max_window_info.setColor(textColor);
            }
        }
    }
}
