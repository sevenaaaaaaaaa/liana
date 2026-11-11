import UIKit

final class VoiceMeterView:UIView {
    private var bars:[UIView]=[]
    private var running=false
    override init(frame:CGRect) {
        super.init(frame:frame); isAccessibilityElement=true; accessibilityLabel="麦克风未录音"
        let row=UIStackView(); row.axis = .horizontal; row.spacing=5; row.alignment = .center; row.translatesAutoresizingMaskIntoConstraints=false; addSubview(row)
        for _ in 0..<13 {
            let bar=UIView(); bar.backgroundColor=LianaPalette.ink; bar.layer.cornerRadius=2
            bar.widthAnchor.constraint(equalToConstant:4).isActive=true; bar.heightAnchor.constraint(equalToConstant:56).isActive=true
            row.addArrangedSubview(bar); bars.append(bar)
        }
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo:centerXAnchor),row.centerYAnchor.constraint(equalTo:centerYAnchor),heightAnchor.constraint(equalToConstant:78)])
        setLevel(0)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setRunning(_ active:Bool) { guard active != running else { return }; running=active; accessibilityLabel=active ? "正在录音" : "麦克风未录音"; setLevel(active ? 0.2 : 0) }
    func setLevel(_ value:Float) {
        let weights:[CGFloat]=[0.25,0.4,0.65,0.45,0.8,0.6,1,0.65,0.85,0.45,0.6,0.35,0.2]
        let amount:CGFloat=running ? (UIAccessibility.isReduceMotionEnabled ? 0.45 : CGFloat(max(0.1,value))) : 0.05
        let apply={ for (index,bar) in self.bars.enumerated() { bar.transform=CGAffineTransform(scaleX:1,y:max(0.05,amount*weights[index])); bar.alpha=self.running ? 1 : 0.4 } }
        if LianaMotion.enabled { UIView.animate(withDuration:0.08,delay:0,options:[.beginFromCurrentState,.allowUserInteraction,.curveEaseOut],animations:apply) } else { apply() }
    }
}
