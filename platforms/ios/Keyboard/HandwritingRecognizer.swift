import Foundation
import JavaScriptCore

/// Bundled HanziLookup recognizer; runs solely on MobileEngine's serial worker.
final class HandwritingRecognizer {
    private let context: JSContext?
    init(bundle: Bundle) {
        guard let script = bundle.url(forResource: "hanzilookup.min", withExtension: "js"),
              let model = bundle.url(forResource: "mmah", withExtension: "json"),
              let js = try? String(contentsOf: script), let data = try? String(contentsOf: model) else { context = nil; return }
        let ctx = JSContext()!
        ctx.evaluateScript(js)
        ctx.setObject(data, forKeyedSubscript: "modelJSON" as NSString)
        ctx.evaluateScript("HanziLookup.data.local=JSON.parse(modelJSON); HanziLookup.data.local.substrokes=HanziLookup.decodeCompact(HanziLookup.data.local.substrokes); modelJSON=null; var matcher=new HanziLookup.Matcher('local'); function recognize(strokes){var result=[]; matcher.match(new HanziLookup.AnalyzedCharacter(strokes),9,function(items){result=items.map(function(x){return x.character;});}); return result;}")
        context = ctx
    }
    func recognize(_ strokes: [[[Double]]]) -> [String] {
        guard strokes.count <= 48, strokes.allSatisfy({ $0.count >= 2 && $0.count <= 2000 }) else { return [] }
        return context?.objectForKeyedSubscript("recognize")?.call(withArguments: [strokes])?.toArray() as? [String] ?? []
    }
}
