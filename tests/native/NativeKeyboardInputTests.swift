import XCTest
import AppKit
import ApplicationServices
@testable import ComputerUseHelper

final class NativeKeyboardInputTests:XCTestCase{
    func testKeyboardReceiverRejectsAnotherControlEvenInsideTheSameObservedWindow()throws{
        let expected=NativeKeyboardReceiver(windowID:7,focusedElement:"document-editor")
        try expected.validate(.init(windowID:7,focusedElement:"document-editor"),equal:==)
        XCTAssertThrowsError(try expected.validate(.init(windowID:7,focusedElement:"human-search-field"),equal:==))
        XCTAssertThrowsError(try expected.validate(.init(windowID:8,focusedElement:"document-editor"),equal:==))
        XCTAssertThrowsError(try expected.validate(nil,equal:==))
        XCTAssertThrowsError(try expected.validate(.init(windowID:7,focusedElement:nil),equal:==))
    }
    func testWindowOnlyShortcutDoesNotAdoptANewFocusedControl()throws{
        let expected=NativeKeyboardReceiver<String>(windowID:7,focusedElement:nil)
        try expected.validate(.init(windowID:7,focusedElement:nil),equal:==)
        XCTAssertThrowsError(try expected.validate(.init(windowID:7,focusedElement:"new-human-field"),equal:==))
    }
    func testTargetBeingForegroundIsNotAForeignDeliveryAndWatchingTracksAdditionalApps()throws{
        let ledger=NativeInputLedger()
        let(tag,id)=try ledger.begin(target:42,window:7,receiver:"editor",plan:.literal("fixture"),foreground:42)
        ledger.observe(tag:tag,deliveredTo:42)
        ledger.watching(id,pid:43);ledger.watching(id,pid:43)
        let receipt=try XCTUnwrap(ledger.receipt(id,foreground:43))
        XCTAssertFalse(receipt.violation);XCTAssertTrue(receipt.target_delivery_observed)
        XCTAssertEqual(receipt.watched_pids,[42,43])
    }
    func testLiteralPlanKeepsUnicodeAndEscapeCharactersWithoutHIDStateOrTextOnKeyUp()throws{
        let literal="OCU 😀 𝄞 é \\n {return}\n\""
        let plan=try NativeInputPlan.literal(literal);plan.bind(pid:42,tag:123456)
        XCTAssertEqual(plan.events.count,2)
        XCTAssertNotEqual(plan.source.sourceStateID,.hidSystemState)
        XCTAssertNotEqual(plan.source.sourceStateID,.combinedSessionState)
        for event in plan.events{
            XCTAssertEqual(event.getIntegerValueField(.eventSourceStateID),Int64(plan.source.sourceStateID.rawValue))
            XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID),42)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData),123456)
            XCTAssertEqual(event.flags,[])
        }
        var units=[UniChar](repeating:0,count:literal.utf16.count);var actual=0
        plan.events[0].keyboardGetUnicodeString(maxStringLength:units.count,actualStringLength:&actual,unicodeString:&units)
        XCTAssertEqual(String(decoding:units.prefix(actual),as:UTF16.self),literal)
        units = [UniChar](repeating:0,count:literal.utf16.count)
        plan.events[1].keyboardGetUnicodeString(maxStringLength:units.count,actualStringLength:&actual,unicodeString:&units)
        // Quartz translates a release's native keycode; it carries no copy of
        // the literal text payload supplied on key-down.
        XCTAssertNotEqual(String(decoding:units.prefix(actual),as:UTF16.self),literal)
    }
    func testKeystrokeTextUsesKeyPositionsWithPrivateShiftAndRefusesKeylessCharacters()throws{
        let plan=try NativeInputPlan.keystrokes("Hi!\n")
        XCTAssertEqual(plan.kind,"keyboard_text");XCTAssertEqual(plan.textUnits,4)
        XCTAssertEqual(plan.events.map{$0.type},[.flagsChanged,.keyDown,.keyUp,.flagsChanged,.keyDown,.keyUp,.flagsChanged,.keyDown,.keyUp,.flagsChanged,.keyDown,.keyUp])
        XCTAssertEqual(plan.events.map{$0.getIntegerValueField(.keyboardEventKeycode)},[56,4,4,56,34,34,56,18,18,56,36,36])
        XCTAssertEqual(plan.events[0].flags,.maskShift);XCTAssertEqual(plan.events[3].flags,[]);XCTAssertEqual(plan.events[1].flags,.maskShift)
        XCTAssertNotEqual(plan.source.sourceStateID,.hidSystemState);XCTAssertNotEqual(plan.source.sourceStateID,.combinedSessionState)
        func text(_ event:CGEvent)->String{var units=[UniChar](repeating:0,count:4);var n=0;event.keyboardGetUnicodeString(maxStringLength:4,actualStringLength:&n,unicodeString:&units);return String(decoding:units.prefix(n),as:UTF16.self)}
        XCTAssertEqual(text(plan.events[1]),"H");XCTAssertEqual(text(plan.events[7]),"!")
        XCTAssertEqual(plan.delays.count,plan.events.count);XCTAssertEqual(plan.delays[0],0)
        // Every press has its own release: shift and each key.
        XCTAssertEqual(plan.releases,[0:3,1:2,4:5,6:9,7:8,10:11])
        XCTAssertThrowsError(try NativeInputPlan.keystrokes("café")){XCTAssertEqual(($0 as? NativeInteractionFailure)?.code,"keyboard_character_unsupported")}
        XCTAssertThrowsError(try NativeInputPlan.keystrokes(""))
    }
    func testPointerGesturesAreWindowBoundTimedAndStayInsideTheWindow()throws{
        let frame=CGRect(x:100,y:50,width:400,height:300)
        let click=try NativeInputPlan.pointer(.init(points:[CGPoint(x:150,y:60)]),window:7,frame:frame,primaryScreenHeight:900)
        XCTAssertEqual(click.events.map{$0.type},[.leftMouseDown,.leftMouseUp]);XCTAssertTrue(click.delays.isEmpty);XCTAssertEqual(click.kind,"pointer_click")
        let hold=try NativeInputPlan.pointer(.init(points:[CGPoint(x:150,y:60)],duration:0.8),window:7,frame:frame,primaryScreenHeight:900)
        XCTAssertEqual(hold.events.map{$0.type},[.leftMouseDown,.leftMouseUp]);XCTAssertEqual(hold.delays,[0,0.8]);XCTAssertEqual(hold.kind,"pointer_long_press")
        let drag=try NativeInputPlan.pointer(.init(points:[CGPoint(x:450,y:200),CGPoint(x:150,y:200)],duration:0.3),window:7,frame:frame,primaryScreenHeight:900)
        XCTAssertEqual(drag.events.first?.type,.leftMouseDown);XCTAssertEqual(drag.events.last?.type,.leftMouseUp)
        XCTAssertTrue(drag.events.dropFirst().dropLast().allSatisfy{$0.type == .leftMouseDragged})
        XCTAssertEqual(drag.events.count,2+19);XCTAssertEqual(drag.delays.reduce(0,+),0.3,accuracy:1e-9)
        XCTAssertEqual(drag.releases,[0:drag.events.count-1]);XCTAssertEqual(drag.kind,"pointer_drag")
        for event in drag.events{XCTAssertEqual(NSEvent(cgEvent:event)?.windowNumber,7);XCTAssertEqual(event.flags,[])}
        // Window-local: the start is 350 points right of the window's left edge.
        XCTAssertEqual(NSEvent(cgEvent:drag.events[0])?.locationInWindow.x ?? 0,350,accuracy:0.5)
        XCTAssertEqual(NSEvent(cgEvent:drag.events.last!)?.locationInWindow.x ?? 0,50,accuracy:0.5)
        XCTAssertThrowsError(try NativeInputPlan.pointer(.init(points:[CGPoint(x:450,y:200),CGPoint(x:600,y:200)],duration:0.3),window:7,frame:frame,primaryScreenHeight:900))
        XCTAssertThrowsError(try NativeInputPlan.pointer(.init(points:[CGPoint(x:150,y:60)],duration:6),window:7,frame:frame,primaryScreenHeight:900))
    }
    func testRepeatedClicksCountEachPressAndModifiersRideOnTheEventsOnly()throws{
        let frame=CGRect(x:100,y:50,width:400,height:300)
        let double=try NativeInputPlan.pointer(.init(points:[CGPoint(x:150,y:60)],clickCount:2,modifiers:[.maskCommand]),window:7,frame:frame,primaryScreenHeight:900)
        XCTAssertEqual(double.events.map{$0.type},[.leftMouseDown,.leftMouseUp,.leftMouseDown,.leftMouseUp])
        XCTAssertEqual(double.events.map{$0.getIntegerValueField(.mouseEventClickState)},[1,1,2,2])
        XCTAssertEqual(double.releases,[0:1,2:3]);XCTAssertTrue(double.delays.isEmpty);XCTAssertEqual(double.kind,"pointer_click")
        for event in double.events{
            XCTAssertEqual(event.flags,.maskCommand);XCTAssertEqual(NSEvent(cgEvent:event)?.windowNumber,7)
            XCTAssertEqual(NSEvent(cgEvent:event)?.modifierFlags.intersection(.deviceIndependentFlagsMask),.command)
        }
        // No flagsChanged press: the modifier is never held down for real.
        XCTAssertFalse(double.events.contains{$0.type == .flagsChanged})
        let triple=try NativeInputPlan.pointer(.init(points:[CGPoint(x:150,y:60)],clickCount:3),window:7,frame:frame,primaryScreenHeight:900)
        XCTAssertEqual(triple.events.map{$0.getIntegerValueField(.mouseEventClickState)},[1,1,2,2,3,3]);XCTAssertTrue(triple.events.allSatisfy{$0.flags == []})
        XCTAssertEqual(NativePointerGesture(points:[.zero],clickCount:3,modifiers:[.maskShift,.maskControl]).name,"Ctrl+Shift+LeftTripleClick")
        for invalid in [NativePointerGesture(points:[CGPoint(x:150,y:60)],clickCount:4),NativePointerGesture(points:[CGPoint(x:150,y:60)],clickCount:0),
                        NativePointerGesture(points:[CGPoint(x:150,y:60)],duration:0.8,clickCount:2),NativePointerGesture(points:[CGPoint(x:150,y:60),CGPoint(x:160,y:60)],duration:0.3,clickCount:2)]{
            XCTAssertThrowsError(try NativeInputPlan.pointer(invalid,window:7,frame:frame,primaryScreenHeight:900)){XCTAssertEqual(($0 as? NativeInteractionFailure)?.code,"invalid_click_count")}
        }
        XCTAssertEqual(try NativeInputPlan.modifierFlags(["cmd","option"]),[.maskCommand,.maskAlternate])
        XCTAssertThrowsError(try NativeInputPlan.modifierFlags(["hyper"])){XCTAssertEqual(($0 as? NativeInteractionFailure)?.code,"invalid_modifier")}
    }
    func testShortcutCarriesOnlyRequestedModifiersAndCreatesNoModifierPresses()throws{
        let plan=try NativeInputPlan.shortcut(["cmd","shift","s"])
        XCTAssertEqual(plan.events.map{$0.type},[.keyDown,.keyUp])
        for event in plan.events{XCTAssertEqual(event.flags,[.maskCommand,.maskShift]);XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode),1)}
        XCTAssertThrowsError(try NativeInputPlan.shortcut(["cmd","s","a"]))
        XCTAssertThrowsError(try NativeInputPlan.shortcut(["cmd","unsupported"]))
    }
    func testUntaggedHumanEventsAreIgnoredAndForeignDeliveryLatchesFailure()throws{
        let ledger=NativeInputLedger();let plan=try NativeInputPlan.literal("secret test text")
        let(tag,id)=try ledger.begin(target:42,window:7,receiver:"editor",plan:plan,foreground:43)
        ledger.observe(tag:0,deliveredTo:43)
        XCTAssertEqual(ledger.receipt(id,foreground:43)?.received_event_count,0)
        ledger.observe(tag:tag,deliveredTo:42)
        XCTAssertEqual(ledger.receipt(id,foreground:43)?.target_delivery_observed,true)
        ledger.observe(tag:tag,deliveredTo:43)
        let receipt=try XCTUnwrap(ledger.receipt(id,foreground:43))
        XCTAssertTrue(receipt.violation);XCTAssertEqual(receipt.received_pids,[42,43])
        XCTAssertThrowsError(try ledger.begin(target:42,window:7,receiver:"editor",plan:plan,foreground:43))
        let encoded=String(data:try JSONEncoder().encode(receipt),encoding:.utf8)!
        XCTAssertFalse(encoded.contains("secret"));XCTAssertFalse(encoded.contains("test text"))
    }
    func testLostObserverRemainsUnknownRatherThanClaimingDelivery()throws{
        let ledger=NativeInputLedger();let(_,id)=try ledger.begin(target:42,window:7,receiver:nil,plan:.shortcut(["return"]),foreground:43)
        ledger.observerLost(pid:43)
        let receipt=try XCTUnwrap(ledger.receipt(id,foreground:43))
        XCTAssertFalse(receipt.observer_available);XCTAssertFalse(receipt.target_delivery_observed)
    }
    func testPointerClickCarriesWindowNumberAndWindowLocalLocationOnAPrivateSource() throws {
        let frame=CGRect(x:80,y:120,width:900,height:640)
        let plan=try NativeInputPlan.click(at:CGPoint(x:384,y:195),window:2341,frame:frame,primaryScreenHeight:1117)
        plan.bind(pid:42,tag:99)
        XCTAssertEqual(plan.events.map(\.type),[.leftMouseDown,.leftMouseUp]);XCTAssertEqual(plan.kind,"pointer_click")
        for event in plan.events {
            XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue:51)!),2341)
            XCTAssertEqual(event.location.x,304,accuracy:0.001);XCTAssertEqual(event.location.y,75,accuracy:0.001)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState),1)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData),99)
            XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID),42)
            XCTAssertEqual(event.flags,[])
            XCTAssertEqual(event.getIntegerValueField(.eventSourceStateID),Int64(plan.source.sourceStateID.rawValue))
        }
        XCTAssertTrue(NativeInputPlan.downTypes.contains(plan.events[0].type));XCTAssertTrue(NativeInputPlan.upTypes.contains(plan.events[1].type))
        XCTAssertThrowsError(try NativeInputPlan.click(at:CGPoint(x:10,y:10),window:2341,frame:frame,primaryScreenHeight:1117))
        XCTAssertThrowsError(try NativeInputPlan.click(at:CGPoint(x:384,y:195),window:0,frame:frame,primaryScreenHeight:1117))
    }
}
