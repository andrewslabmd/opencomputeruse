import XCTest
import ApplicationServices
@testable import ComputerUseHelper

private final class FakeNativeAccess: NativeInteractionAccess {
    var inputCalls=[String]()
    func inputText(_ id:String,_ text:String)throws -> String {inputCalls.append(id+":"+text);return "fake-input-trace"}
    var pointerCalls=[String]()
    var active=true
    func appActive()throws -> Bool {active}
    var gestures=[NativePointerGesture]()
    func pointerGesture(_ id:String,_ gesture:NativePointerGesture)throws -> String {
        gestures.append(gesture)
        pointerCalls.append(id+"@"+gesture.points.map{"\(Int($0.x)),\(Int($0.y))"}.joined(separator:"->")+(gesture.duration>0 ? "/\(Int(gesture.duration*1000))ms" : ""))
        return "fake-pointer-trace"
    }
    var focusedElement: String?
    var keyboardCalls=[String]()
    func keyboardFocusWithin(_ ids:[String])throws -> Bool {focusedElement.map{ids.contains($0)} ?? true}
    func keyboardText(_ id:String,_ text:String,within ids:[String])throws -> String {keyboardCalls.append(id+":"+text);return "fake-keyboard-trace"}
    var keyboardFocus: String?
    var keyboardWindow: String?
    func ownsKeyboardFocus(_ id: String) throws -> Bool {
        if let keyboardWindow, id == keyboardWindow { return true }
        if let keyboardFocus { return id == keyboardFocus }
        return (values[id + ":AXFocused"] as? NSNumber)?.boolValue == true
    }
    var calls: [String] = []
    var capabilitiesRead = 0
    var actionReadFailures = Set<String>()
    var declared: [String: NativeSupportedOperations] = [:]
    var errors: [String: AXError] = [:]
    var values: [String: CFTypeRef] = [:]
    var ignoredWrites = Set<String>()
    var selectionMembers: [String: Set<String>] = [:]
    var readCounts: [String: Int] = [:]
    var disappearOnRead: [String: Int] = [:]
    var forcedSelections: [String: [String]] = [:]
    var pending = false
    var disabled: String?
    var bars: [String: NativeInteractionNode] = [:]
    var liveFrames: [String: CGRect] = [:]
    var resizeOnValue: CGRect?
    var invalidAfterValue = false
    var identityInvalid = false
    func validate(_ node: NativeInteractionNode) throws {
        if identityInvalid || liveFrames[node.id].map({ $0 != node.frame }) == true {
            throw NativeInteractionFailure(code: "native_target_changed", message: "target changed")
        }
    }
    func refreshAfterMutation(_ node: NativeInteractionNode) throws -> NativeInteractionNode {
        if identityInvalid { throw NativeInteractionFailure(code: "native_target_changed", message: "identity changed") }
        return NativeInteractionNode(id: node.id, role: node.role, subrole: node.subrole,
            frame: liveFrames[node.id] ?? node.frame, children: node.children, offscreen: node.offscreen)
    }
    func validateRelated(_ node: NativeInteractionNode, owner: NativeInteractionNode) throws {}
    func parameterized(_ id: String, _ a: String, _ p: CFTypeRef) throws -> CFTypeRef? { values[id + ":" + a] }
    func scrollBar(_ owner: NativeInteractionNode, vertical: Bool) throws -> NativeInteractionNode? { bars[owner.id] }
    func read(_ id: String, _ a: String) throws -> CFTypeRef? {
        if a == "AXEnabled", disabled == id { return kCFBooleanFalse }
        let key = id + ":" + a
        readCounts[key, default: 0] += 1
        if disappearOnRead[key] == readCounts[key] { return [] as CFArray }
        return values[key]
    }
    func write(_ id: String, _ a: String, _ v: CFTypeRef) throws -> AXError {
        let key = id + ":" + a; calls.append(key)
        let error = errors[key] ?? .attributeUnsupported
        if error == .success && ["AXSelectedChildren", "AXSelectedRows"].contains(a) {
            guard let requested = v as? [String], let permitted = selectionMembers[key],
                  requested.allSatisfy({ permitted.contains($0) }) else { return .illegalArgument }
        }
        if error == .success && !ignoredWrites.contains(key) {
            values[key] = forcedSelections[key].map { $0 as CFArray } ?? v
            if a == "AXMain" { keyboardWindow = id }
            if a == "AXFocused", keyboardFocus != nil { keyboardFocus = id }
            if a == "AXValue" {
                if let resizeOnValue { liveFrames[id] = resizeOnValue }
                if invalidAfterValue { identityInvalid = true }
            }
        }
        return error
    }
    func perform(_ id: String, _ a: String) throws -> NativeCallOutcome {
        let key = id + ":" + a; calls.append(key)
        return pending ? .pending : .returned(errors[key] ?? .actionUnsupported)
    }
    func element(_ id: String) throws -> CFTypeRef { id as CFString }
    var rebuilt: [String: String] = [:]
    func sameControl(_ element: CFTypeRef, as id: String) throws -> Bool { let live = element as! String; return live == id || rebuilt[live] == id }
    func actionNames(_ id: String) throws -> [String] { capabilitiesRead += 1; if actionReadFailures.contains(id) { throw NativeInteractionFailure(code:"native_capabilities_failed",message:"No actions on layout") }; return declared[id]?.actions ?? [] }
    func canWrite(_ id: String, _ attribute: String) throws -> Bool { capabilitiesRead += 1; return errors[id + ":" + attribute] == .success }
    func capabilities(_ id: String) throws -> NativeSupportedOperations {
        capabilitiesRead += 1
        return declared[id] ?? NativeSupportedOperations(id: id, actions: [], writableAttributes: [])
    }
}

final class NativeInteractionTests: XCTestCase {
    func testWebContentWithoutAccessibilityOperationFallsBackToWindowBoundPointerClick() throws {
        let access=FakeNativeAccess()
        let canvas=node("canvas","AXGroup",CGRect(x:0,y:0,width:50,height:50))
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:CGPoint(x:10,y:20)),chain:[canvas,node("web","AXWebArea"),node("window","AXWindow")])
        XCTAssertEqual(access.pointerCalls,["canvas@10,20"]);XCTAssertEqual(result.status,"sent");XCTAssertEqual(result.behavior,"pointer_click")
        XCTAssertEqual(result.input_trace_ids,["fake-pointer-trace"]);XCTAssertEqual(result.operations.map(\.kind),["pointer"])
    }
    func testPositionSensitiveWebPressUsesPointerAtTheRequestedPoint() throws {
        let access=FakeNativeAccess();access.errors["canvas:AXPress"] = .success
        access.declared["canvas"]=NativeSupportedOperations(id:"canvas",actions:["AXPress"],writableAttributes:[])
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:CGPoint(x:30,y:12)),chain:[node("canvas","AXImage",CGRect(x:0,y:0,width:50,height:50)),node("web","AXWebArea")])
        XCTAssertEqual(access.pointerCalls,["canvas@30,12"]);XCTAssertFalse(access.calls.contains("canvas:AXPress"));XCTAssertEqual(result.behavior,"pointer_click")
    }
    func testNativeCustomPressStaysAccessibility() throws {
        let access=FakeNativeAccess();access.errors["cell:AXPress"] = .success
        access.declared["cell"]=NativeSupportedOperations(id:"cell",actions:["AXPress"],writableAttributes:[])
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("cell","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(access.calls,["cell:AXPress"]);XCTAssertTrue(access.pointerCalls.isEmpty);XCTAssertEqual(result.status,"completed")
    }
    func testInactiveAppReportsActivationRequiredBeforeAnyPointerOrMenuDispatch() throws {
        let access=FakeNativeAccess();access.active=false
        access.errors["popup:AXPress"] = .success;access.errors["button:AXPress"] = .success
        let pointer=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:CGPoint(x:10,y:10)),chain:[node("canvas","AXGroup"),node("web","AXWebArea")])
        XCTAssertEqual(pointer.code,"app_activation_required");XCTAssertEqual(pointer.effect,"not_attempted");XCTAssertTrue(access.pointerCalls.isEmpty)
        let popup=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("popup","AXPopUpButton")])
        XCTAssertEqual(popup.code,"app_activation_required");XCTAssertTrue(access.calls.isEmpty)
        // An ordinary press does not need the app's activation.
        let button=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("button","AXButton"),node("web","AXWebArea")])
        XCTAssertEqual(button.status,"completed");XCTAssertEqual(access.calls,["button:AXPress"])
    }
    func testNativeAppNonControlStaysNoEffectWithoutPointerInput() throws {
        let access=FakeNativeAccess()
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("display","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(result.status,"no_effect");XCTAssertTrue(access.pointerCalls.isEmpty)
    }
    func testWebPressThatWasAttemptedIsNeverRepeatedAsPointer() throws {
        let access=FakeNativeAccess();access.errors["button:AXPress"] = .cannotComplete
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("button","AXButton"),node("web","AXWebArea")])
        XCTAssertEqual(result.code,"native_operation_uncertain");XCTAssertTrue(access.pointerCalls.isEmpty)
    }
    func testTextOnASurfaceWithoutAnEditorIsSentAsKeystrokesWhileFocusIsOnThatSurface() throws {
        let access=FakeNativeAccess();access.keyboardWindow="window";access.focusedElement="surface"
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"wifi"),chain:[node("surface","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(access.keyboardCalls,["surface:wifi"]);XCTAssertTrue(access.inputCalls.isEmpty);XCTAssertTrue(access.calls.isEmpty)
        XCTAssertEqual(result.status,"sent");XCTAssertEqual(result.behavior,"keyboard_text");XCTAssertEqual(result.effect,"keyboard_text_sent")
        XCTAssertEqual(result.input_trace_ids,["fake-keyboard-trace"]);XCTAssertEqual(result.operations.map(\.name),["KeyboardText"])
        XCTAssertNil(result.text_check)
    }
    func testSurfaceKeystrokesAlsoGoWhenNothingInTheAppHasKeyboardFocusAndSubmitAddsReturn() throws {
        let access=FakeNativeAccess();access.keyboardWindow="window"
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"go",submit:true),chain:[node("canvas","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(access.keyboardCalls,["canvas:go\n"]);XCTAssertEqual(result.effect,"keyboard_text_return_sent")
    }
    func testSurfaceKeystrokesNeverGoWhileAnotherControlHasKeyboardFocus() throws {
        let access=FakeNativeAccess();access.keyboardWindow="window";access.focusedElement="sidebar-search"
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"wifi"),chain:[node("surface","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(result.code,"keyboard_focus_elsewhere");XCTAssertEqual(result.effect,"not_attempted");XCTAssertTrue(access.keyboardCalls.isEmpty)
    }
    func testSurfaceKeystrokesRefuseControlsReplacementAnInactiveAppAndABackgroundWindow() throws {
        let access=FakeNativeAccess();access.keyboardWindow="window"
        let button=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"x"),chain:[node("button","AXButton"),node("window","AXWindow")])
        XCTAssertEqual(button.code,"target_not_editable")
        let replace=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"x",replace:true),chain:[node("surface","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(replace.code,"text_replace_unavailable")
        access.active=false
        let inactive=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"x"),chain:[node("surface","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(inactive.code,"app_activation_required")
        access.active=true;access.keyboardWindow=nil
        let background=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"x"),chain:[node("surface","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(background.code,"keyboard_target_unavailable")
        XCTAssertTrue(access.keyboardCalls.isEmpty)
        // The direct Accessibility method still requires an editor.
        let direct=try NativeInteractionExecutor(access:access).execute(.init(kind:"type",point:point,text:"x"),chain:[node("surface","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(direct.code,"target_not_editable")
    }
    func testLongPressHoldsAWindowBoundPointerAtThePoint() throws {
        let access=FakeNativeAccess()
        var action=NativeInteractionAction(kind:"long_press",point:CGPoint(x:10,y:20));action.duration=0.8
        let result=try NativeInteractionExecutor(access:access).execute(action,chain:[node("surface","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(access.pointerCalls,["surface@10,20/800ms"]);XCTAssertEqual(result.status,"sent")
        XCTAssertEqual(result.behavior,"pointer_long_press");XCTAssertEqual(result.operations.map(\.name),["LeftLongPress"])
        let none=try NativeInteractionExecutor(access:access).execute(.init(kind:"long_press",point:point),chain:[node("surface","AXGroup")])
        XCTAssertEqual(none.code,"invalid_pointer_duration");XCTAssertEqual(access.pointerCalls.count,1)
    }
    func testPointerDragSwipesFromTheStartToTheDestinationOverItsDuration() throws {
        let access=FakeNativeAccess()
        var action=NativeInteractionAction(kind:"drag",point:CGPoint(x:80,y:20),destination:CGPoint(x:10,y:20));action.pointer=true
        let result=try NativeInteractionExecutor(access:access).execute(action,chain:[node("surface","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(access.pointerCalls,["surface@80,20->10,20/300ms"]);XCTAssertEqual(result.behavior,"pointer_drag")
        action.duration=0.12
        _=try NativeInteractionExecutor(access:access).execute(action,chain:[node("surface","AXGroup")])
        XCTAssertEqual(access.pointerCalls.last,"surface@80,20->10,20/120ms")
    }
    func testDragOnANativeNonControlNeedsExplicitPointerButWebContentUsesItAutomatically() throws {
        let access=FakeNativeAccess()
        let native=try NativeInteractionExecutor(access:access).execute(.init(kind:"drag",point:point,destination:CGPoint(x:50,y:5)),chain:[node("group","AXGroup"),node("window","AXWindow")])
        XCTAssertEqual(native.code,"unsupported_background_drag");XCTAssertTrue(access.pointerCalls.isEmpty)
        let web=try NativeInteractionExecutor(access:access).execute(.init(kind:"drag",point:point,destination:CGPoint(x:50,y:5)),chain:[node("canvas","AXGroup"),node("web","AXWebArea")])
        XCTAssertEqual(web.behavior,"pointer_drag");XCTAssertEqual(access.pointerCalls,["canvas@5,5->50,5/300ms"])
    }
    func testExplicitPointerClickSkipsAccessibilityAndUsesElementCentreOutsidePoint() throws {
        let access=FakeNativeAccess();access.errors["button:AXPress"] = .success
        var action=NativeInteractionAction(kind:"click",point:CGPoint(x:500,y:500));action.pointer=true
        let result=try NativeInteractionExecutor(access:access).execute(action,chain:[node("button","AXButton",CGRect(x:0,y:0,width:20,height:40))])
        XCTAssertEqual(access.pointerCalls,["button@10,20"]);XCTAssertTrue(access.calls.isEmpty);XCTAssertEqual(result.status,"sent")
    }
    func testLiteralKeyboardInputPreservesSelectionAndDefersSubmitWithoutContentSetters() throws {
        let access=FakeNativeAccess();access.keyboardFocus="text"
        access.values["text:AXValue"]="A😀B" as CFString
        var range=CFRange(location:1,length:2)
        access.values["text:AXSelectedTextRange"]=try XCTUnwrap(AXValueCreate(.cfRange,&range))
        let text="\\n{return}\n𝄞"
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:text,submit:true),chain:[node("text","AXTextArea")])
        XCTAssertEqual(access.inputCalls,["text:"+text]);XCTAssertTrue(access.calls.isEmpty)
        XCTAssertEqual(result.status,"sent");XCTAssertEqual(result.text_check?.expected,"A"+text+"B")
        XCTAssertEqual(result.text_check?.submit,true);XCTAssertFalse(result.submit_ready)
    }
    func testKeyboardReplacementSelectsTextWithoutChangingItsValueThroughAX() throws {
        let access=FakeNativeAccess();access.keyboardFocus="text"
        access.values["text:AXValue"]="A😀B" as CFString;access.errors["text:AXSelectedTextRange"] = .success
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"replacement",replace:true),chain:[node("text","AXTextArea")])
        XCTAssertEqual(access.calls,["text:AXSelectedTextRange"]);XCTAssertEqual(access.inputCalls,["text:replacement"])
        XCTAssertEqual(result.text_check?.expected,"replacement")
    }
    func testIgnoredReplacementSelectionPreventsKeyboardInput() throws {
        let access=FakeNativeAccess();access.keyboardFocus="text"
        access.values["text:AXValue"]="current" as CFString;access.errors["text:AXSelectedTextRange"] = .success
        access.ignoredWrites.insert("text:AXSelectedTextRange")
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"input_text",point:point,text:"replacement",replace:true),chain:[node("text","AXTextArea")])
        XCTAssertEqual(result.code,"text_selection_not_applied");XCTAssertTrue(access.inputCalls.isEmpty)
    }
    func testEditorClickSelectsItsWindowEvenWhenItsLocalFocusIsAlreadyTrue() throws {
        let access=FakeNativeAccess(); var mapped=CFRange(location:0,length:0)
        access.keyboardFocus="other-editor";access.keyboardWindow="other-window"
        access.values["text:AXFocused"]=kCFBooleanTrue
        access.values["text:AXRangeForPosition"]=try XCTUnwrap(AXValueCreate(.cfRange,&mapped))
        for key in ["window:AXMain","text:AXFocused","text:AXSelectedTextRange"] {access.errors[key] = .success}
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("text","AXTextArea"),node("window","AXWindow")])
        XCTAssertEqual(result.effect,"caret_positioned")
        XCTAssertEqual(access.calls,["window:AXMain","text:AXFocused","text:AXSelectedTextRange"])
        XCTAssertEqual(access.keyboardWindow,"window");XCTAssertEqual(access.keyboardFocus,"text")
    }
    func testIgnoredWindowFocusCannotClaimEditorFocusOrMoveCaret() throws {
        let access=FakeNativeAccess();var mapped=CFRange(location:0,length:0)
        access.keyboardFocus="other-editor";access.keyboardWindow="other-window"
        access.values["text:AXRangeForPosition"]=try XCTUnwrap(AXValueCreate(.cfRange,&mapped))
        access.errors["window:AXMain"] = .success;access.errors["text:AXSelectedTextRange"] = .success
        access.ignoredWrites.insert("window:AXMain")
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("text","AXTextArea"),node("window","AXWindow")])
        XCTAssertEqual(result.status,"failed");XCTAssertEqual(result.code,"text_focus_unavailable")
        XCTAssertEqual(access.calls,["window:AXMain"])
    }
    func testControlFocusRemainsAvailableWhenWindowMainIsNotWritable() throws {
        let access=FakeNativeAccess();var mapped=CFRange(location:0,length:0)
        access.keyboardFocus="other-editor";access.keyboardWindow="other-window"
        access.values["text:AXRangeForPosition"]=try XCTUnwrap(AXValueCreate(.cfRange,&mapped))
        access.errors["text:AXFocused"] = .success;access.errors["text:AXSelectedTextRange"] = .success
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("text","AXTextArea"),node("window","AXWindow")])
        XCTAssertEqual(result.effect,"caret_positioned")
        XCTAssertEqual(access.calls,["text:AXFocused","text:AXSelectedTextRange"])
    }
    func testModalEditorFocusDoesNotSelectTheParentDocumentWindow() throws {
        let access=FakeNativeAccess();var mapped=CFRange(location:0,length:0)
        access.keyboardFocus="other-editor";access.keyboardWindow="modal"
        access.values["text:AXRangeForPosition"]=try XCTUnwrap(AXValueCreate(.cfRange,&mapped))
        for key in ["window:AXMain","text:AXFocused","text:AXSelectedTextRange"] {access.errors[key] = .success}
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),chain:[node("text","AXTextField"),node("sheet","AXSheet"),node("window","AXWindow")])
        XCTAssertEqual(result.effect,"caret_positioned");XCTAssertFalse(access.calls.contains("window:AXMain"))
    }
    func testNativeLinkedScrollerWithDegenerateBoundsUsesRelativePosition() throws {
        let access = FakeNativeAccess(); let bar = node("bar", "AXScrollBar")
        access.bars["scroll"] = bar
        for (key, value) in ["AXMinValue":0.0, "AXMaxValue":0.0, "AXValue":0.6] { access.values["bar:" + key] = NSNumber(value:value) }
        access.errors["bar:AXValue"] = .success
        let owner = node("scroll", "AXScrollArea", children:[node("document", "AXGroup", CGRect(x:0,y:0,width:100,height:400)),bar])
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind:"scroll",point:point),chain:[owner])
        XCTAssertEqual(result.effect, "scroll_position_changed")
        XCTAssertEqual((access.values["bar:AXValue"] as? NSNumber)?.doubleValue ?? 0, 0.6+1.0/3, accuracy:1e-9)
    }
    func testLinkedScrollerOptionalBoundsCanBePartiallyAvailable() throws {
        for (minimum, maximum) in [(0.0, nil), (nil, 1.0), (nil, 0.0)] as [(Double?, Double?)] {
            let access=FakeNativeAccess();let bar=node("bar","AXScrollBar")
            access.bars["scroll"]=bar;access.values["bar:AXValue"]=NSNumber(value:0)
            if let minimum {access.values["bar:AXMinValue"]=NSNumber(value:minimum)}
            if let maximum {access.values["bar:AXMaxValue"]=NSNumber(value:maximum)}
            access.errors["bar:AXValue"] = .success
            let owner=node("scroll","AXScrollArea",children:[node("document","AXGroup",CGRect(x:0,y:0,width:100,height:400)),bar])
            let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"scroll",point:point),chain:[owner])
            XCTAssertEqual(result.effect,"scroll_position_changed")
        }
    }
    func testUnknownAdjustableRangeCannotBecomeNormalizedByRoleAlone() throws {
        for role in ["AXScrollBar", "AXSlider"] {
            let access = FakeNativeAccess()
            access.values["control:AXMinValue"] = NSNumber(value:0)
            access.values["control:AXMaxValue"] = NSNumber(value:0)
            access.errors["control:AXValue"] = .success
            let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"drag",point:point,destination:point),chain:[node("control",role)])
            XCTAssertEqual(result.status,"failed"); XCTAssertTrue(access.calls.isEmpty)
        }
    }
    func testUnusableRangeDoesNotHideNativePageAction() throws {
        let access = FakeNativeAccess(); let bar = node("bar", "AXScrollBar")
        access.bars["scroll"] = bar
        access.values["bar:AXValue"] = NSNumber(value:20)
        access.errors["bar:AXValue"] = .success
        access.errors["scroll:AXScrollDownByPage"] = .success
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind:"scroll",point:point),chain:[node("scroll","AXScrollArea",children:[bar])])
        XCTAssertEqual(result.status,"completed"); XCTAssertEqual(access.calls,["scroll:AXScrollDownByPage"])
    }
    func testRevealUsesOnlyExactOffscreenHandleAndDoesNotPressOrFocus() throws {
        var target = node("link", "AXLink"); target.offscreen = true
        let root = node("window", "AXWindow", children:[target])
        XCTAssertThrowsError(try NativePointResolver.elementChain(root:root,elementID:"link"))
        let chain = try NativePointResolver.elementChain(root:root,elementID:"link",allowOffscreen:true)
        let access = FakeNativeAccess(); access.errors["link:AXScrollToVisible"] = .success
        access.declared["link"] = .init(id:"link",actions:["AXScrollToVisible"],writableAttributes:[])
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"scroll_to_visible",point:point),chain:chain)
        XCTAssertEqual(result.status,"completed"); XCTAssertEqual(access.calls,["link:AXScrollToVisible"])
    }
    func testOpenUsesAdvertisedNativeOperationOnExactTargetPath() throws {
        let access = FakeNativeAccess()
        access.declared["item"] = .init(id:"item",actions:["AXOpen"],writableAttributes:[])
        access.errors["item:AXOpen"] = .success
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"open",point:point),chain:[node("label","AXStaticText"),node("item","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.status,"completed");XCTAssertEqual(result.behavior,"open")
        XCTAssertEqual(access.calls,["item:AXOpen"])
    }
    func testRepeatedAndModifiedClicksUseWindowBoundPointerEvenOnAPressableControl() throws {
        let access=FakeNativeAccess();access.errors["button:AXPress"] = .success
        var double=NativeInteractionAction(kind:"click",point:CGPoint(x:10,y:20));double.clickCount=2
        let result=try NativeInteractionExecutor(access:access).execute(double,chain:[node("button","AXButton"),node("window","AXWindow")])
        XCTAssertEqual(result.status,"sent");XCTAssertEqual(result.behavior,"pointer_click");XCTAssertTrue(access.calls.isEmpty)
        XCTAssertEqual(access.gestures.last?.clickCount,2);XCTAssertEqual(result.operations.map(\.name),["LeftDoubleClick"])
        var modified=NativeInteractionAction(kind:"click",point:CGPoint(x:10,y:20));modified.modifiers=[.maskCommand,.maskShift]
        let cmd=try NativeInteractionExecutor(access:access).execute(modified,chain:[node("row","AXRow"),node("window","AXWindow")])
        XCTAssertEqual(cmd.operations.map(\.name),["Shift+Cmd+LeftClick"]);XCTAssertEqual(access.gestures.last?.modifiers,[.maskCommand,.maskShift])
        access.active=false
        let inactive=try NativeInteractionExecutor(access:access).execute(double,chain:[node("button","AXButton")])
        XCTAssertEqual(inactive.code,"app_activation_required");XCTAssertEqual(access.gestures.count,2)
    }
    func testPerformActionSendsOnlyAnActionTheExactTargetAdvertises() throws {
        let access=FakeNativeAccess()
        access.declared["stepper"] = .init(id:"stepper",actions:["AXDecrement","AXIncrement"],writableAttributes:[])
        access.declared["group"] = .init(id:"group",actions:["AXCancel"],writableAttributes:[])
        access.errors["stepper:AXIncrement"] = .success;access.errors["group:AXCancel"] = .success
        var increment=NativeInteractionAction(kind:"perform_action",point:point);increment.actionName="AXIncrement"
        let done=try NativeInteractionExecutor(access:access).execute(increment,chain:[node("stepper","AXIncrementor"),node("group","AXGroup")])
        XCTAssertEqual(done.status,"completed");XCTAssertEqual(done.behavior,"perform_action");XCTAssertEqual(access.calls,["stepper:AXIncrement"])
        // A container's action is never used for the target.
        var cancel=NativeInteractionAction(kind:"perform_action",point:point);cancel.actionName="AXCancel"
        let refused=try NativeInteractionExecutor(access:access).execute(cancel,chain:[node("stepper","AXIncrementor"),node("group","AXGroup")])
        XCTAssertEqual(refused.code,"unsupported_native_action");XCTAssertEqual(refused.effect,"not_attempted")
        XCTAssertEqual(refused.supported?.map(\.id),["stepper","group"]);XCTAssertEqual(access.calls,["stepper:AXIncrement"])
    }
    func testPerformActionWithoutNameListsActionsAndSendsNothing() throws {
        let access=FakeNativeAccess()
        access.declared["cell"] = .init(id:"cell",actions:["AXShowMenu","Name:Archive\nTarget:0x0\nSelector:(null)"],writableAttributes:[])
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"perform_action",point:point),chain:[node("cell","AXCell"),node("table","AXTable")])
        XCTAssertEqual(result.status,"completed");XCTAssertEqual(result.behavior,"list_actions");XCTAssertTrue(access.calls.isEmpty)
        XCTAssertEqual(result.supported?.first?.actions,["AXShowMenu","Name:Archive\nTarget:0x0\nSelector:(null)"]);XCTAssertTrue(result.operations.isEmpty)
    }
    func testPerformActionMenuNeedsActivationAndPressKeepsPressBehavior() throws {
        let access=FakeNativeAccess();access.active=false
        access.declared["cell"] = .init(id:"cell",actions:["AXPress","AXShowMenu"],writableAttributes:[])
        access.errors["cell:AXPress"] = .success;access.errors["cell:AXShowMenu"] = .success
        var menu=NativeInteractionAction(kind:"perform_action",point:point);menu.actionName="AXShowMenu"
        XCTAssertEqual(try NativeInteractionExecutor(access:access).execute(menu,chain:[node("cell","AXCell")]).code,"app_activation_required")
        XCTAssertTrue(access.calls.isEmpty)
        var press=NativeInteractionAction(kind:"perform_action",point:point);press.actionName="AXPress"
        let pressed=try NativeInteractionExecutor(access:access).execute(press,chain:[node("cell","AXCell")])
        XCTAssertEqual(pressed.behavior,"press");XCTAssertEqual(access.calls,["cell:AXPress"])
    }
    func testDirectScrollerAdjustmentRequiresTheSameNativeOwnershipLink() throws {
        let access=FakeNativeAccess();let bar=node("bar","AXScrollBar",CGRect(x:0,y:0,width:10,height:100))
        access.bars["scroll"]=bar
        for (key,value) in ["AXMinValue":0.0,"AXMaxValue":0.0,"AXValue":0.0] {access.values["bar:"+key]=NSNumber(value:value)}
        access.errors["bar:AXValue"] = .success
        let result=try NativeInteractionExecutor(access:access).execute(.init(kind:"drag",point:point,destination:CGPoint(x:5,y:80)),chain:[bar,node("scroll","AXScrollArea",children:[bar])])
        XCTAssertEqual(result.effect,"value_matches")
        XCTAssertEqual((access.values["bar:AXValue"] as? NSNumber)?.doubleValue,0.8)
    }
    private let point = CGPoint(x: 5, y: 5)
    private func node(_ id: String, _ role: String, _ frame: CGRect? = CGRect(x: 0, y: 0, width: 100, height: 100), children: [NativeInteractionNode] = []) -> NativeInteractionNode {
        NativeInteractionNode(id: id, role: role, subrole: nil, frame: frame, children: children)
    }
    func testEmptyContainerCannotPressOffPointDescendant() throws {
        let clear = node("clear", "AXButton", CGRect(x: 50, y: 50, width: 20, height: 20))
        let root = node("root", "AXGroup", children: [clear])
        let chain = try NativePointResolver.chain(root: root, nativeHitIDs: ["root"], point: point)
        XCTAssertEqual(chain.map(\.id), ["root"])
        let access = FakeNativeAccess(); access.errors["clear:AXPress"] = .success
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: chain)
        XCTAssertEqual(result.status, "no_effect")
        XCTAssertTrue(access.calls.isEmpty)
    }
    func testRefinementIsIndependentOfSiblingOrderAndDepth() throws {
        let button = node("button", "AXButton", CGRect(x: 0, y: 0, width: 10, height: 10))
        let layout = node("layout", "AXGroup", children: [node("deep", "AXGroup")])
        for children in [[layout, button], [button, layout]] {
            let chain = try NativePointResolver.chain(root: node("root", "AXWindow", children: children), nativeHitIDs: ["root"], point: point)
            XCTAssertEqual(chain.first?.id, "button")
        }
    }
    func testAmbiguousAndCrossingSiblingsFail() throws {
        for frames in [[CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: 10)],
                       [CGRect(x: 0, y: 0, width: 10, height: 20), CGRect(x: 0, y: 0, width: 20, height: 10)]] {
            XCTAssertThrowsError(try NativePointResolver.chain(root: node("root", "AXWindow", children: [node("a", "AXButton", frames[0]), node("b", "AXButton", frames[1])]), nativeHitIDs: ["root"], point: point))
        }
    }
    func testPreciseNativeHitNeverSearchesSibling() throws {
        let root = node("root", "AXWindow", children: [node("a", "AXButton", CGRect(x: 30, y: 30, width: 10, height: 10)), node("b", "AXButton")])
        XCTAssertTrue(try NativePointResolver.chain(root: root, nativeHitIDs: ["a", "root"], point: point).isEmpty)
        XCTAssertThrowsError(try NativePointResolver.chain(root: root, nativeHitIDs: ["a", "b"], point: point))
    }
    func testOffscreenDescendantsAreExcluded() throws {
        var child = node("off", "AXButton", CGRect(x: 0, y: 0, width: 10, height: 10)); child.offscreen = true
        let chain = try NativePointResolver.chain(root: node("root", "AXWindow", children: [child]), nativeHitIDs: ["root"], point: point)
        XCTAssertEqual(chain.first?.id, "root")
    }
    func testButtonUsesExactIdentityWithoutCapabilityScan() throws {
        let access = FakeNativeAccess(); access.errors["button:AXPress"] = .success
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: [node("button", "AXButton"), node("root", "AXWindow")])
        XCTAssertEqual(access.calls, ["button:AXPress"]); XCTAssertEqual(access.capabilitiesRead, 0)
        XCTAssertEqual(result.behavior, "press"); XCTAssertNil(result.effect)
        XCTAssertEqual(result.operations.first?.receiver_id, "button")
    }
    func testLeftClickSelectionNeverClaimsShowMenuOrNavigation() throws {
        let access = FakeNativeAccess()
        access.declared["row"] = .init(id: "row", actions: ["AXShowMenu"], writableAttributes: ["AXSelected"])
        access.errors["row:AXSelected"] = .success
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: [node("row", "AXRow"), node("outline", "AXOutline")])
        XCTAssertEqual(access.calls, ["row:AXSelected"])
        XCTAssertEqual(result.behavior, "select"); XCTAssertEqual(result.effect, "selection_set")
        XCTAssertEqual(result.operations.first?.name, "AXSelected")
    }
    func testSelectionFallbackUsesOwningContainerAndAuditsActualReceiver() throws {
        let access = FakeNativeAccess(); access.errors["outline:AXSelectedRows"] = .success
        access.values["outline:AXRows"] = ["row"] as CFArray
        access.selectionMembers["outline:AXSelectedRows"] = ["row"]
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: [node("row", "AXRow"), node("outline", "AXOutline")])
        XCTAssertEqual(result.element_id, "row")
        XCTAssertEqual(result.operations.last?.receiver_id, "outline")
        XCTAssertEqual(access.calls, ["outline:AXSelectedRows"])
    }
    func testUncertainFailureDoesNotTryAnotherTargetAndRetainsAudit() throws {
        let access = FakeNativeAccess(); access.errors["button:AXPress"] = .cannotComplete
        access.errors["ancestor:AXPress"] = .success
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: [node("button", "AXButton"), node("ancestor", "AXButton")])
        XCTAssertEqual(result.status, "failed"); XCTAssertEqual(result.code, "native_operation_uncertain")
        XCTAssertEqual(access.calls, ["button:AXPress"])
        XCTAssertEqual(result.operations.first?.native_error, AXError.cannotComplete.rawValue)
    }
    func testDisabledTargetNeverFallsBackToAncestor() throws {
        let access = FakeNativeAccess(); access.disabled = "button"
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: [node("button", "AXButton"), node("ancestor", "AXButton")])
        XCTAssertEqual(result.status, "failed"); XCTAssertTrue(access.calls.isEmpty)
    }
    func testPendingExactHandleCannotBeDispatchedAgain() {
        let registry = NativeActionRegistry()
        let a = AXUIElementCreateApplication(42)
        let same = AXUIElementCreateApplication(42)
        let first = registry.begin(a, action: "AXPress")
        XCTAssertTrue(first.isNew)
        XCTAssertFalse(registry.begin(same, action: "AXPress").isNew)
        XCTAssertTrue(registry.begin(a, action: "AXShowMenu").isNew)
        first.completion.store(.success)
        XCTAssertTrue(registry.begin(same, action: "AXPress").isNew)
    }
    func testPendingActionIsNotCompletedAndHasNoFallback() throws {
        let access = FakeNativeAccess(); access.pending = true
        access.declared["button"] = .init(id: "button", actions: ["AXShowMenu"], writableAttributes: [])
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "right_click", point: point), chain: [node("button", "AXButton"), node("root", "AXWindow")])
        XCTAssertEqual(result.status, "pending"); XCTAssertEqual(result.effect, "native_call_pending")
        XCTAssertEqual(access.calls, ["button:AXShowMenu"])
    }
    func testReadonlyTypingReturnsSupportedDetailsWithoutMutation() throws {
        let access = FakeNativeAccess()
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "type", point: point, text: "hello"), chain: [node("group", "AXGroup")])
        XCTAssertEqual(result.status, "failed"); XCTAssertEqual(result.code, "target_not_editable")
        XCTAssertNotNil(result.supported); XCTAssertTrue(access.calls.isEmpty)
    }
    func testReplacingTextChecksValueAndDoesNotScanCapabilities() throws {
        let access = FakeNativeAccess(); access.errors["field:AXValue"] = .success
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "type", point: point, text: "hello😀", replace: true), chain: [node("field", "AXTextField")])
        XCTAssertEqual(result.status, "completed"); XCTAssertEqual(result.effect, "text_value_matches")
        XCTAssertEqual(access.capabilitiesRead, 2)
    }
    func testTextResizeRefreshesSameReceiverBeforeCursorAndSubmit() throws {
        let access = FakeNativeAccess()
        for attribute in ["AXValue", "AXSelectedTextRange", "AXFocused"] { access.errors["text:" + attribute] = .success }
        access.resizeOnValue = CGRect(x: 200,y: 10,width: 250,height: 30)
        let result = try NativeInteractionExecutor(access: access).execute(
            .init(kind: "type",point: point,text: "new text",replace: true,submit: true),chain: [node("text","AXTextField")])
        XCTAssertEqual(result.status, "completed"); XCTAssertEqual(result.effect, "text_value_matches")
        XCTAssertTrue(result.submit_ready)
        XCTAssertEqual(access.calls, ["text:AXValue", "text:AXSelectedTextRange", "text:AXFocused"])
    }
    func testAlreadyFocusedEditorDoesNotNeedUnsupportedFocusSetterForSubmit() throws {
        let access = FakeNativeAccess(); access.errors["text:AXValue"] = .success
        access.values["text:AXFocused"] = kCFBooleanTrue
        let result = try NativeInteractionExecutor(access: access).execute(
            .init(kind: "type",point: point,text: "new text",replace: true,submit: true),chain: [node("text","AXTextField")])
        XCTAssertEqual(result.status, "completed"); XCTAssertTrue(result.submit_ready)
        XCTAssertEqual(access.calls, ["text:AXValue"])
    }
    func testUnexpectedGeometryBeforeTextWriteStillStopsMutation() throws {
        let access = FakeNativeAccess(); access.errors["text:AXValue"] = .success
        access.liveFrames["text"] = CGRect(x: 200,y: 10,width: 250,height: 30)
        let result = try NativeInteractionExecutor(access: access).execute(
            .init(kind: "type",point: point,text: "new text",replace: true),chain: [node("text","AXTextField")])
        XCTAssertEqual(result.status, "failed"); XCTAssertTrue(access.calls.isEmpty)
    }
    func testIdentityChangeAfterTextWriteDoesNotSendFollowups() throws {
        let access = FakeNativeAccess(); access.errors["text:AXValue"] = .success; access.invalidAfterValue = true
        let result = try NativeInteractionExecutor(access: access).execute(
            .init(kind: "type",point: point,text: "new text",replace: true,submit: true),chain: [node("text","AXTextField")])
        XCTAssertEqual(result.status, "failed"); XCTAssertFalse(result.submit_ready)
        XCTAssertEqual(access.calls, ["text:AXValue"]); XCTAssertEqual(result.operations.first?.outcome,"accepted")
    }
    func testPostMutationReceiverUsesFreshGeometryWithoutOldPointRequirement() {
        let resized = CGRect(x: 200,y: 10,width: 250,height: 30)
        XCTAssertFalse(NativeValidationPhase.point.matches(actual: resized,expected: resized,point: point,linked: false))
        XCTAssertTrue(NativeValidationPhase.receiver.matches(actual: resized,expected: resized,point: point,linked: false))
        XCTAssertFalse(NativeValidationPhase.receiver.matches(actual: resized.offsetBy(dx: 2,dy: 0),expected: resized,point: point,linked: false))
    }
    func testUnconfirmedTextCannotBeSubmittedDespiteSuccessfulSetter() throws {
        let access = FakeNativeAccess(); access.errors["field:AXValue"] = .success
        access.ignoredWrites.insert("field:AXValue")
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "type", point: point, text: "expected", replace: true, submit: true), chain: [node("field", "AXTextField")])
        XCTAssertEqual(result.status, "failed"); XCTAssertEqual(result.code, "text_change_unconfirmed")
        XCTAssertFalse(result.submit_ready); XCTAssertFalse(access.calls.contains("field:AXFocused"))
    }
    func testUnicodeCaretInsertionUsesUTF16AndRejectsSplitSurrogates() throws {
        let edit = NativeInteractionExecutor.replacingSelection("a😀z", range: CFRange(location: 1, length: 2), text: "λ")
        XCTAssertEqual(edit?.text, "aλz"); XCTAssertEqual(edit?.cursor, 2)
        XCTAssertNil(NativeInteractionExecutor.replacingSelection("a😀z", range: CFRange(location: 2, length: 0), text: "x"))
        XCTAssertNil(NativeInteractionExecutor.replacingSelection("abc", range: CFRange(location: 5, length: 0), text: "x"))
    }
    func testDragUsesValidatedAdjustableIdentityAndClampsNumericValue() throws {
        let access = FakeNativeAccess(); access.values["slider:AXMinValue"] = NSNumber(value: 0); access.values["slider:AXMaxValue"] = NSNumber(value: 100); access.errors["slider:AXValue"] = .success
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "drag", point: point, destination: CGPoint(x: 1000, y: 5)), chain: [node("slider", "AXSlider", CGRect(x: 0, y: 0, width: 100, height: 10))])
        XCTAssertEqual(result.behavior, "adjust"); XCTAssertEqual(access.values["slider:AXValue"] as? NSNumber, NSNumber(value: 100))
    }
    func testScrollStopsIfLaterPageIsPending() throws {
        let access = FakeNativeAccess(); access.pending = true
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "scroll", point: point, direction: "down", amount: 20), chain: [node("scroll", "AXScrollArea")])
        XCTAssertEqual(result.status, "pending"); XCTAssertEqual(access.calls.count, 1)
    }
    func testReadonlySectionDoesNotBlockOwningSelection() throws {
        let access = FakeNativeAccess(); access.disabled = "section"; access.actionReadFailures.insert("section"); access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["section"] as CFArray
        access.values["section:AXChildren"] = ["image"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["image"]
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: [node("image", "AXImage"), NativeInteractionNode(id:"section",role:"AXList",subrole:"AXSectionList",frame:node("section","AXList").frame,children:[]), NativeInteractionNode(id:"list",role:"AXList",subrole:"AXCollectionList",frame:node("list","AXList").frame,children:[])])
        XCTAssertEqual(result.status, "completed"); XCTAssertEqual(result.effect, "selection_set")
        XCTAssertEqual(access.calls, ["list:AXSelectedChildren"])
    }
    func testReadonlyPageDoesNotBlockOwningScroller() throws {
        let access = FakeNativeAccess(); access.disabled = "page"; access.pending = true
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "scroll", point: point), chain: [node("page", "AXPage"), node("scroll", "AXScrollArea")])
        XCTAssertEqual(result.status, "pending"); XCTAssertEqual(access.calls, ["scroll:AXScrollDownByPage"])
    }
    func testActionAttributeErrorNeverTriggersAnotherAction() throws {
        let access = FakeNativeAccess(); access.errors["scroll:AXScrollDownByPage"] = .attributeUnsupported
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "scroll", point: point), chain: [node("scroll", "AXScrollArea")])
        XCTAssertEqual(result.code, "native_operation_uncertain"); XCTAssertEqual(access.calls, ["scroll:AXScrollDownByPage"])
    }
    func testCaretPositionIsCollapsedAndReadBack() throws {
        let access = FakeNativeAccess(); var mapped = CFRange(location: 7, length: 1)
        access.values["text:AXRangeForPosition"] = try XCTUnwrap(AXValueCreate(.cfRange, &mapped))
        access.errors["text:AXFocused"] = .success; access.errors["text:AXSelectedTextRange"] = .success
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: [node("text", "AXTextArea")])
        XCTAssertEqual(result.effect, "caret_positioned"); XCTAssertEqual(result.status, "completed")
        var selected = CFRange(); let raw = try XCTUnwrap(access.values["text:AXSelectedTextRange"])
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &selected))
        XCTAssertEqual(selected.location, 7); XCTAssertEqual(selected.length, 0)
    }
    func testIgnoredCaretSetterCannotReportPositioned() throws {
        let access = FakeNativeAccess(); var mapped = CFRange(location: 7, length: 1)
        access.values["text:AXRangeForPosition"] = try XCTUnwrap(AXValueCreate(.cfRange, &mapped))
        access.errors["text:AXFocused"] = .success; access.errors["text:AXSelectedTextRange"] = .success
        access.ignoredWrites.insert("text:AXSelectedTextRange")
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "click", point: point), chain: [node("text", "AXTextArea")])
        XCTAssertEqual(result.status, "failed"); XCTAssertEqual(result.code, "text_position_not_applied")
    }
    func testScrollUsesOwnedBarAndConfirmsDirection() throws {
        let access = FakeNativeAccess(); let bar = node("bar", "AXScrollBar")
        access.bars["scroll"] = bar
        for (key, value) in ["AXMinValue":0.0, "AXMaxValue":1.0, "AXValue":0.0] { access.values["bar:" + key] = NSNumber(value:value) }
        access.errors["bar:AXValue"] = .success
        let owner = node("scroll", "AXScrollArea", children:[node("document", "AXGroup", CGRect(x:0,y:0,width:100,height:400)),bar])
        let result = try NativeInteractionExecutor(access: access).execute(.init(kind: "scroll", point: point), chain: [node("page", "AXPage"),owner])
        XCTAssertEqual(result.effect, "scroll_position_changed"); XCTAssertEqual(access.calls, ["bar:AXValue"])
        XCTAssertEqual((access.values["bar:AXValue"] as? NSNumber)?.doubleValue ?? 0, 1.0/3, accuracy:1e-9)
    }
    func testStandardScrollerWithoutOptionalBoundsAndContainerItemSelection() throws {
        let access = FakeNativeAccess(); let bar = node("bar", "AXScrollBar")
        access.bars["scroll"] = bar; access.values["bar:AXValue"] = NSNumber(value:0); access.errors["bar:AXValue"] = .success
        let owner = node("scroll", "AXScrollArea", children:[node("document", "AXGroup", CGRect(x:0,y:0,width:100,height:400)),bar])
        let scroll = try NativeInteractionExecutor(access: access).execute(.init(kind:"scroll",point:point),chain:[owner])
        XCTAssertEqual(scroll.effect,"scroll_position_changed")
        access.values["item:AXSelected"] = kCFBooleanFalse; access.errors["list:AXSelectedChildren"] = .success
        access.values["image:AXSelected"] = kCFBooleanFalse
        access.values["list:AXChildren"] = ["section"] as CFArray
        access.values["section:AXChildren"] = ["item"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["item"]
        let select = try NativeInteractionExecutor(access: access).execute(.init(kind:"click",point:point),chain:[node("image","AXImage"),node("item","AXGroup"),NativeInteractionNode(id:"section",role:"AXList",subrole:"AXSectionList",frame:node("section","AXList").frame,children:[]),NativeInteractionNode(id:"list",role:"AXList",subrole:"AXCollectionList",frame:node("list","AXList").frame,children:[])])
        XCTAssertEqual(select.element_id,"item"); XCTAssertEqual(select.effect,"selection_set")
        XCTAssertEqual((access.values["list:AXSelectedChildren"] as? [String]),["item"])
    }
    func testImageAndLabelUseContainerItemEvenWhenBothExposeSelected() throws {
        for role in ["AXImage", "AXStaticText"] {
            let access = FakeNativeAccess()
            access.values["leaf:AXSelected"] = kCFBooleanFalse
            access.values["list:AXChildren"] = ["item"] as CFArray
            access.errors["list:AXSelectedChildren"] = .success
            access.selectionMembers["list:AXSelectedChildren"] = ["item"]
            let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
                chain:[node("leaf",role),node("item","AXGroup"),node("list","AXList")])
            XCTAssertEqual(result.element_id,"item"); XCTAssertEqual(result.effect,"selection_set")
            XCTAssertEqual(access.values["list:AXSelectedChildren"] as? [String],["item"])
        }
    }
    func testProviderRejectsImageWhenOnlyItsContainingItemIsSelectable() throws {
        let access = FakeNativeAccess(); access.errors["list:AXSelectedChildren"] = .success
        access.selectionMembers["list:AXSelectedChildren"] = ["item"]
        XCTAssertEqual(try access.write("list","AXSelectedChildren",["image"] as CFArray),.illegalArgument)
        XCTAssertNil(access.values["list:AXSelectedChildren"])
    }
    func testUnrelatedRowNeverSentToWritableContainer() throws {
        let access = FakeNativeAccess(); access.errors["outline:AXSelectedRows"] = .success
        access.values["outline:AXRows"] = ["different_row"] as CFArray
        access.selectionMembers["outline:AXSelectedRows"] = ["different_row"]
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("row","AXRow"),node("outline","AXOutline")])
        XCTAssertEqual(result.status,"no_effect"); XCTAssertTrue(access.calls.isEmpty)
    }
    func testNestedCellUsesActualRowMembershipRatherThanCellRole() throws {
        let access = FakeNativeAccess(); access.errors["table:AXSelectedRows"] = .success
        access.values["table:AXChildren"] = ["column"] as CFArray
        access.values["table:AXRows"] = ["row"] as CFArray
        access.selectionMembers["table:AXSelectedRows"] = ["row"]
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("label","AXStaticText"),node("cell","AXCell"),node("row","AXRow"),node("table","AXTable")])
        XCTAssertEqual(result.element_id,"row"); XCTAssertEqual(access.calls,["table:AXSelectedRows"])
    }
    func testMembershipChangeBeforeDispatchStopsWithoutMutation() throws {
        let access = FakeNativeAccess(); access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["item"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["item"]
        access.disappearOnRead["list:AXChildren"] = 2
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("label","AXStaticText"),node("item","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.code,"native_target_changed"); XCTAssertTrue(access.calls.isEmpty)
    }
    func testIgnoredValidSelectionRemainsFailureWithoutAnotherTarget() throws {
        let access = FakeNativeAccess(); access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["item"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["item"]
        access.ignoredWrites.insert("list:AXSelectedChildren")
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("label","AXStaticText"),node("item","AXGroup"),node("list","AXList")])
        // The immediate readback cannot distinguish ignored from not-yet-reflected;
        // the fresh capture decides, and nothing is sent twice.
        XCTAssertEqual(result.status,"completed"); XCTAssertEqual(result.effect,"selection_unconfirmed")
        XCTAssertEqual(result.selection_check?.receiver_id,"item"); XCTAssertEqual(access.calls,["list:AXSelectedChildren"])
    }
    func testSidebarStillShowingPreviousRowIsLeftToTheFreshCaptureNotFailed() throws {
        // Finder's sidebar (2026-10-14/15): the write is accepted and the window
        // navigates, but the immediate readback still shows the previous row.
        let access = FakeNativeAccess(); access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["recents","item"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["recents","item"]
        access.values["list:AXSelectedChildren"] = ["recents"] as CFArray
        access.ignoredWrites.insert("list:AXSelectedChildren")
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("label","AXStaticText"),node("item","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.status,"completed"); XCTAssertNil(result.code)
        XCTAssertEqual(result.effect,"selection_unconfirmed"); XCTAssertEqual(result.selection_check?.receiver_id,"item")
        XCTAssertEqual(access.calls,["list:AXSelectedChildren"])
    }
    func testRebuiltSelectedRowAfterNavigationIsConfirmedNotFailed() throws {
        let access = FakeNativeAccess(); access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["item"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["item"]
        access.forcedSelections["list:AXSelectedChildren"] = ["item-rebuilt"]; access.rebuilt["item-rebuilt"] = "item"
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("label","AXStaticText"),node("item","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.status,"completed"); XCTAssertEqual(result.effect,"selection_set")
    }
    func testChangedButUnverifiableSelectionIsUnconfirmedWithoutRetry() throws {
        let access = FakeNativeAccess(); access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["item"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["item"]
        access.values["list:AXSelectedChildren"] = ["previous"] as CFArray
        access.forcedSelections["list:AXSelectedChildren"] = []
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("label","AXStaticText"),node("item","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.status,"completed"); XCTAssertEqual(result.selection_check?.receiver_id,"item")
        XCTAssertEqual(access.calls,["list:AXSelectedChildren"])
    }
    func testSelectionOfAdditionalItemsIsNotRequestedSingleSelection() throws {
        let access = FakeNativeAccess(); access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["item","other"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["item","other"]
        access.forcedSelections["list:AXSelectedChildren"] = ["item","other"]
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("label","AXStaticText"),node("item","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.code,"selection_not_applied")
    }
    func testImageInsideCustomPressControlNeverSelectsOuterList() throws {
        let access = FakeNativeAccess(); access.errors["control:AXPress"] = .success
        access.declared["control"] = .init(id:"control",actions:["AXPress"],writableAttributes:[])
        access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["control"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["control"]
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("image","AXImage"),node("control","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.behavior,"press"); XCTAssertEqual(access.calls,["control:AXPress"])
    }
    func testAmbiguousLiveMembershipStopsWithoutChoosingFirst() throws {
        let access = FakeNativeAccess(); access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["image","item"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["image","item"]
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("image","AXImage"),node("item","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.code,"ambiguous_selection_item"); XCTAssertTrue(access.calls.isEmpty)
    }

    func testReadonlyTextFieldLabelSelectsItsActualRowWithoutFocusingLabel() throws {
        let access = FakeNativeAccess(); access.values["label:AXSelected"] = kCFBooleanFalse
        access.errors["label:AXFocused"] = .success
        access.errors["table:AXSelectedRows"] = .success
        access.values["table:AXRows"] = ["row"] as CFArray
        access.selectionMembers["table:AXSelectedRows"] = ["row"]
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("label","AXTextField"),node("cell","AXCell"),node("row","AXRow"),node("table","AXTable")])
        XCTAssertEqual(result.element_id,"row"); XCTAssertEqual(access.calls,["table:AXSelectedRows"])
    }
    func testEditableTextFieldInsideRowPositionsCaretInsteadOfSelectingRow() throws {
        let access = FakeNativeAccess(); var mapped = CFRange(location:3,length:0)
        access.values["editor:AXRangeForPosition"] = try XCTUnwrap(AXValueCreate(.cfRange,&mapped))
        access.errors["editor:AXFocused"] = .success; access.errors["editor:AXSelectedTextRange"] = .success
        access.errors["table:AXSelectedRows"] = .success
        access.values["table:AXRows"] = ["row"] as CFArray
        access.selectionMembers["table:AXSelectedRows"] = ["row"]
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("editor","AXTextField"),node("cell","AXCell"),node("row","AXRow"),node("table","AXTable")])
        XCTAssertEqual(result.effect,"caret_positioned"); XCTAssertFalse(access.calls.contains("table:AXSelectedRows"))
    }

    func testReadonlyItemLayoutDoesNotRequireUnsupportedActionEnumeration() throws {
        let access = FakeNativeAccess(); access.disabled = "item"
        access.actionReadFailures.insert("item")
        access.errors["list:AXSelectedChildren"] = .success
        access.values["list:AXChildren"] = ["item"] as CFArray
        access.selectionMembers["list:AXSelectedChildren"] = ["item"]
        let result = try NativeInteractionExecutor(access:access).execute(.init(kind:"click",point:point),
            chain:[node("image","AXImage"),node("item","AXGroup"),node("list","AXList")])
        XCTAssertEqual(result.effect,"selection_set"); XCTAssertEqual(access.calls,["list:AXSelectedChildren"])
    }

    func testExactReferenceDoesNotChooseAnOverlappingSibling() throws {
        let root = node("root", "AXWindow", children: [node("a", "AXButton"), node("b", "AXButton")])
        XCTAssertEqual(try NativePointResolver.elementChain(root: root, elementID: "b").map(\.id), ["b", "root"])
        XCTAssertThrowsError(try NativePointResolver.elementChain(root: root, elementID: "foreign"))
    }
    func testNativeSubmitDoesNotRequestKeyboardFocus() throws {
        let access = FakeNativeAccess();access.errors["field:AXValue"] = .success
        access.errors["field:AXConfirm"] = .success
        access.declared["field"] = .init(id: "field", actions: ["AXConfirm"], writableAttributes: ["AXValue"])
        var action = NativeInteractionAction(kind: "type", point: point); action.text="new";action.replace=true;action.submit=true
        let result = try NativeInteractionExecutor(access: access).execute(action, chain: [node("field", "AXTextField")])
        XCTAssertEqual(result.status,"completed");XCTAssertEqual(access.calls,["field:AXValue","field:AXConfirm"])
        XCTAssertFalse(result.submit_ready)
    }
    func testNativeSubmitRejectionNeverFallsThroughToReturn() throws {
        let access = FakeNativeAccess();access.errors["field:AXValue"] = .success
        access.declared["field"] = .init(id:"field",actions:["AXConfirm"],writableAttributes:["AXValue"])
        var action = NativeInteractionAction(kind:"type",point:point);action.text="new";action.replace=true;action.submit=true
        let r=try NativeInteractionExecutor(access:access).execute(action,chain:[node("field","AXTextField")])
        XCTAssertEqual(r.status,"failed");XCTAssertFalse(r.submit_ready);XCTAssertFalse(access.calls.contains("field:AXFocused"))
    }
    func testUniqueSelectionUsesUTF16AndRejectsOverlappingDuplicates() throws {
        let access=FakeNativeAccess();access.values["field:AXValue"]="🧠 Budget review" as CFString
        access.errors["field:AXSelectedTextRange"] = .success
        var action=NativeInteractionAction(kind:"select_text",point:point);action.text="Budget review"
        let r=try NativeInteractionExecutor(access:access).execute(action,chain:[node("field","AXTextArea")])
        XCTAssertEqual(r.effect,"selection_matches");var range=CFRange()
        let raw=access.values["field:AXSelectedTextRange"]!
        XCTAssertTrue(AXValueGetValue(unsafeBitCast(raw,to:AXValue.self),.cfRange,&range));XCTAssertEqual(range.location,3);XCTAssertEqual(range.length,13)
        access.values["field:AXValue"]="aaa" as CFString;access.calls=[];action.text="aa"
        let ambiguous=try NativeInteractionExecutor(access:access).execute(action,chain:[node("field","AXTextArea")])
        XCTAssertEqual(ambiguous.code,"text_ambiguous");XCTAssertTrue(access.calls.isEmpty)
    }
    func testIgnoredSelectionIsNotReportedApplied() throws {
        let access=FakeNativeAccess();access.values["field:AXValue"]="Budget review" as CFString
        access.errors["field:AXSelectedTextRange"] = .success;access.ignoredWrites.insert("field:AXSelectedTextRange")
        var action=NativeInteractionAction(kind:"select_text",point:point);action.text="Budget review"
        let result=try NativeInteractionExecutor(access:access).execute(action,chain:[node("field","AXTextArea")])
        XCTAssertEqual(result.code,"text_selection_not_applied");XCTAssertEqual(result.status,"failed")
    }

}
