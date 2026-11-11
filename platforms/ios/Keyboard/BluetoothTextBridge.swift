import CoreBluetooth
import Foundation

/// Created only after an explicit Connect/Scan action. No typing context leaves the keyboard.
final class BluetoothTextBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Device { let peripheral: CBPeripheral; var name: String; var rssi: Int }
    var onChange: (() -> Void)?
    var onText: ((BLETextDecoder.Event) -> Void)?
    private(set) var status = "未连接。HID 请在系统蓝牙设置配对；BLE 可在这里扫描。"
    private(set) var devices: [Device] = []
    private(set) var characteristics: [CBCharacteristic] = []
    private(set) var subscribed: CBCharacteristic?
    private var central: CBCentralManager?
    private var selected: CBPeripheral?
    private var pendingAction: (() -> Void)?
    private var deadline: DispatchWorkItem?
    private var scanning = false
    private var discovering = 0
    private var decoder = BLETextDecoder()
    private let defaults = UserDefaults.standard

    func setFormat(_ format: BLETextDecoder.Format) { decoder = BLETextDecoder(format: format) }

    private func publish(_ message: String) { status = message; onChange?() }

    private func powered(_ action: @escaping () -> Void) {
        if central == nil {
            pendingAction = action
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if central?.state == .poweredOn { action() }
        else { pendingAction = action; reportState() }
    }

    private func reportState() {
        switch central?.state {
        case .poweredOn:
            let action = pendingAction; pendingAction = nil; action?()
        case .poweredOff: publish("蓝牙已关闭，请在系统设置开启后重试。")
        case .unauthorized: pendingAction = nil; publish("蓝牙权限未允许，请在系统设置允许松萝访问蓝牙。")
        case .unsupported: pendingAction = nil; publish("此设备或模拟器不支持 BLE。")
        default: publish("正在等待蓝牙就绪…")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            deadline?.cancel(); scanning = false
            selected = nil; subscribed = nil; characteristics = []; decoder.reset()
        }
        reportState()
    }

    func scan() {
        stop()
        devices = []
        powered { [weak self] in
            guard let self else { return }
            self.scanning = true
            self.central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            self.publish("正在扫描 BLE（15 秒）…请选择你的设备。")
            self.timeout(after: 15) { [weak self] in
                guard let self else { return }
                self.central?.stopScan(); self.scanning = false
                self.publish(self.devices.isEmpty ? "未找到设备。请确认设备正在广播 BLE；HID 设备请使用系统配对。" : "扫描结束，点击设备连接。")
            }
        }
    }

    func connectLast() {
        stop()
        guard let value = defaults.string(forKey: "ble.lastDevice"), let id = UUID(uuidString: value) else {
            publish("还没有连接记录，请先扫描并选择设备。")
            return
        }
        powered { [weak self] in
            guard let self, let peripheral = self.central?.retrievePeripherals(withIdentifiers: [id]).first else {
                self?.publish("找不到上次设备，请重新扫描。")
                return
            }
            self.connect(peripheral)
        }
    }

    func connect(_ peripheral: CBPeripheral) {
        guard central?.state == .poweredOn else { return }
        guard selected !== peripheral else { return }
        deadline?.cancel(); central?.stopScan(); scanning = false
        if let selected { central?.cancelPeripheralConnection(selected) }
        selected = peripheral; peripheral.delegate = self
        characteristics = []; subscribed = nil; decoder.reset()
        publish("正在连接 \(peripheral.name ?? "BLE 设备")…")
        central?.connect(peripheral)
        timeout(after: 12) { [weak self] in self?.fail("连接超时，请靠近设备后重试。") }
    }

    func stop() {
        pendingAction = nil
        deadline?.cancel(); deadline = nil
        central?.stopScan(); scanning = false
        let previous = selected
        selected = nil; subscribed = nil; characteristics = []; decoder.reset()
        if let previous { central?.cancelPeripheralConnection(previous) }
        publish("已断开。点击扫描或连接上次设备。")
    }

    private func fail(_ message: String) { stop(); publish(message) }

    private func timeout(after seconds: Double, action: @escaping () -> Void) {
        deadline?.cancel()
        let work = DispatchWorkItem(block: action)
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning, devices.count < 30, !devices.contains(where: { $0.peripheral.identifier == peripheral.identifier }) else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名 BLE"
        devices.append(Device(peripheral: peripheral, name: name, rssi: RSSI.intValue))
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard selected === peripheral else { central.cancelPeripheralConnection(peripheral); return }
        publish("已连接，正在读取服务…")
        peripheral.discoverServices(nil)
        timeout(after: 12) { [weak self] in self?.fail("读取服务超时，请重新连接。") }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard selected === peripheral else { return }
        fail("连接失败：\(error?.localizedDescription ?? "设备不可用")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard selected === peripheral else { return }
        fail("设备已断开，请手动重连。")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard selected === peripheral else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else { fail("设备没有可读的 BLE 服务。HID 请使用系统配对。"); return }
        discovering = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard selected === peripheral else { return }
        if error == nil {
            characteristics += (service.characteristics ?? []).filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        }
        discovering -= 1
        guard discovering == 0 else { return }
        deadline?.cancel()
        let saved = defaults.string(forKey: "ble.lastCharacteristic")
        let savedService = defaults.string(forKey: "ble.lastService")
        if defaults.string(forKey: "ble.lastDevice") == peripheral.identifier.uuidString,
           let known = characteristics.first(where: { $0.uuid.uuidString == saved && $0.service?.uuid.uuidString == savedService }) {
            subscribe(known)
        } else {
            publish(characteristics.isEmpty ? "没有 Notify／Indicate 通道，无法接收文字。" : "选择设备文档指定的文字通知通道。")
        }
    }

    func subscribe(_ characteristic: CBCharacteristic) {
        guard let selected, characteristics.contains(where: { $0 === characteristic }) else { return }
        if let subscribed { selected.setNotifyValue(false, for: subscribed) }
        subscribed = characteristic; decoder.reset()
        selected.setNotifyValue(true, for: characteristic)
        publish("正在订阅文字通知…")
        timeout(after: 8) { [weak self] in self?.fail("订阅超时，请重新连接。") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard selected === peripheral, subscribed === characteristic else { return }
        deadline?.cancel()
        guard error == nil, characteristic.isNotifying else { fail("订阅失败，该通道可能需要设备端授权。"); return }
        defaults.set(peripheral.identifier.uuidString, forKey: "ble.lastDevice")
        defaults.set(characteristic.uuid.uuidString, forKey: "ble.lastCharacteristic")
        defaults.set(characteristic.service?.uuid.uuidString, forKey: "ble.lastService")
        publish("已连接 \(peripheral.name ?? "设备")，等待换行结尾的文字。")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected === peripheral, subscribed === characteristic, characteristic.isNotifying else { return }
        guard error == nil, let data = characteristic.value else { publish("接收失败，请重试或重新连接。"); return }
        do {
            for event in try decoder.append(data) { onText?(event) }
        } catch {
            fail("数据不符合文字协议（UTF-8＋换行，或 JSON Lines）。不支持直接传原始音频。")
        }
    }
}
