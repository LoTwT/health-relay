import UIKit
@preconcurrency import AVFoundation

@MainActor final class RelayViewController:UIViewController {
    private var coordinator:SyncCoordinator?
    private let stack=UIStackView();private let statusLabel=UILabel();private let detailLabel=UILabel()
    private var privacyCover:UIView?
    override func viewDidLoad(){
        super.viewDidLoad();title="health-relay";view.backgroundColor = .systemBackground
        let scroll=UIScrollView();scroll.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(scroll)
        stack.axis = .vertical;stack.spacing=16;stack.translatesAutoresizingMaskIntoConstraints=false;scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:24),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-24),stack.leadingAnchor.constraint(equalTo:scroll.frameLayoutGuide.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:scroll.frameLayoutGuide.trailingAnchor,constant:-24)])
        statusLabel.font = .preferredFont(forTextStyle:.title2);statusLabel.numberOfLines=0;stack.addArrangedSubview(statusLabel)
        label("Apple Health → 已配对的三星手机\n保持两端解锁并打开应用，使用可互通的 Wi-Fi。")
        do{
            let support=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            let prior=try PairingVault.read(String.self,key:"installation") != nil
            let primary=support.appendingPathComponent("HealthRelay/state.sqlite")
            let recovery=support.appendingPathComponent("HealthRelay/recovery.sqlite")
            let store:SyncStore
            if FileManager.default.fileExists(atPath:recovery.path){store=try SyncStore(url:recovery,priorIdentityExists:true)}
            else{do{store=try SyncStore(url:primary,priorIdentityExists:prior)}catch{store=try SyncStore(url:recovery,priorIdentityExists:true)}}
            if !prior{try PairingVault.save(newID(),key:"installation")}
            coordinator=SyncCoordinator(store:store);coordinator?.onUpdate={[weak self] in self?.refresh()}
            button("读取健康权限与来源"){[weak self] in self?.chooseSources()}
            button("扫描配对二维码"){[weak self] in self?.scan()}
            button("同步"){[weak self] in self?.coordinator?.run()}
            button("停止本次同步"){[weak self] in self?.coordinator?.stop()}
            button("设置与结果详情"){[weak self] in self?.settings()}
            detailLabel.numberOfLines=0;detailLabel.font = .preferredFont(forTextStyle:.body);stack.addArrangedSubview(detailLabel)
            label("已写入 Health Connect 不代表三星健康已显示。请在三星健康核对睡眠会话、阶段、时长、运动与距离。")
            refresh()
        }catch{statusLabel.text="需要恢复设置：\((error as? RelayError)?.rawValue ?? "数据库不可用")"}
        NotificationCenter.default.addObserver(self,selector:#selector(background),name:UIApplication.willResignActiveNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(foreground),name:UIApplication.didBecomeActiveNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(background),name:UIApplication.protectedDataWillBecomeUnavailableNotification,object:nil)
    }
    @objc private func background(){coordinator?.stop();guard privacyCover==nil,let window=view.window else{return};let cover=UIView(frame:window.bounds);cover.autoresizingMask=[.flexibleWidth,.flexibleHeight];cover.backgroundColor = .systemBackground;window.addSubview(cover);privacyCover=cover}
    @objc private func foreground(){privacyCover?.removeFromSuperview();privacyCover=nil}
    private func button(_ title:String,_ action:@escaping @MainActor ()->Void){
        let b=UIButton(type:.system);b.configuration = .filled();b.configuration?.title=title;b.configuration?.cornerStyle = .large
        b.addAction(UIAction{_ in action()},for:.touchUpInside);stack.addArrangedSubview(b)
    }
    private func label(_ text:String){let label=UILabel();label.text=text;label.numberOfLines=0;label.font = .preferredFont(forTextStyle:.body);label.adjustsFontForContentSizeCategory=true;stack.addArrangedSubview(label)}
    private func refresh(){
        guard let c=coordinator else{return};statusLabel.text=c.status
        do{
            let d=try c.store.dataset
            let paired=try PairingVault.read(Pairing.self,key:"pairing")
            detailLabel.text="睡眠来源：\(d.sources.sleep ?? "未选")\n运动来源：\(d.sources.workout ?? "未选")\n固定历史起点：\(d.historyStart ?? "首次同步时保存前 30 天")\n配对：\(paired == nil ? "未配对":"已保存")\n上次尝试：\(try c.store.get(String.self,"meta","lastAttempt") ?? "尚未尝试")\n上次本轮完成：\(try c.store.get(String.self,"meta","lastComplete") ?? "尚未完成")\n待发送：\(try c.store.pending().count) 组；历史待核对：\(try c.store.list(String.self,"unavailable").count) 条"
        }catch{detailLabel.text="需要恢复设置"}
    }
    private func chooseSources(){
        guard let c=coordinator,!c.busy else{return}
        Task{
            do{
                c.update("正在请求健康读取并发现来源")
                try await c.reader.authorize()
                let lower=try c.store.dataset.historyStart.map(WireTime.milliseconds) ?? (WireTime.now()-30*24*60*60*1000)
                let sleep=try await c.reader.sources(kind:"sleep",lowerMs:lower-48*60*60*1000)
                let workouts=try await c.reader.sources(kind:"workout",lowerMs:lower)
                selectSource(sleep,kind:"sleep"){[weak self] in self?.selectSource(workouts,kind:"workout"){c.update("来源读取完成；空结果不证明已获读取权限")}}
            }catch{show("读取失败","请在系统健康权限检查读取设置，并确认 Apple Watch 的记录已出现在 Apple Health。")}
        }
    }
    private func selectSource(_ choices:[SourceChoice],kind:String,completion:@escaping @MainActor ()->Void){
        guard let c=coordinator else{return}
        let watches=choices.filter(\.recognizableWatch)
        if watches.count==1,let d=try? c.store.dataset,(kind=="sleep" ? d.sources.sleep:d.sources.workout)==nil {try? c.store.select(kind:kind,bundle:watches[0].bundleIdentifier)}
        let alert=UIAlertController(title:kind=="sleep" ? "选择睡眠来源":"选择运动来源",message:choices.isEmpty ? "没有可读取来源，可能与权限或尚无记录有关。":"每类仅选择一个来源。更换已选来源需清除本应用导入并按原范围重建。",preferredStyle:.actionSheet)
        for choice in choices{
            let title="\(choice.name) · \(choice.devices.sorted().joined(separator:",")) · \(choice.count) 条 · \(WireTime.string(choice.latestMs))"
            alert.addAction(UIAlertAction(title:title,style:.default){[weak self] _ in
                do{try c.store.select(kind:kind,bundle:choice.bundleIdentifier);self?.refresh();completion()}
                catch{self?.prepareRebuild(newSource:(kind,choice.bundleIdentifier));completion()}
            })
        }
        alert.addAction(UIAlertAction(title:"保留当前选择 / 暂不导入",style:.cancel){_ in completion()})
        alert.popoverPresentationController?.sourceView=view;present(alert,animated:true)
    }
    private func scan(recoveryMode:Bool=false){
        guard let c=coordinator,!c.busy else{return}
        let scanner=ScannerViewController()
        scanner.scanned={[weak self] text in
            self?.dismiss(animated:true)
            Task{
                do{
                    let code=try WireCodec.decode(PairingCode.self,Data(text.utf8))
                    c.update("请在三星手机确认配对")
                    let sender=try PairingVault.read(String.self,key:"installation") ?? newID()
                    let needsRecovery=try c.store.get(Bool.self,"meta","recovery")==true
                    let mode = recoveryMode || needsRecovery ? "recovery":"normal"
                    let(result,_)=try await c.lan.pair(code,dataset:c.store.dataset,mode:mode,senderId:sender)
                    if let recovery=result["recoveryInfo"] as? [String:Any]{try c.store.put("meta","receiverRecovery",JSONSerialization.data(withJSONObject:recovery))}
                    c.lan.close();c.update("配对已保存")
                }catch{self?.show("配对未完成",(error as? RelayError)?.rawValue ?? "检查相机、本地网络权限及接收端二维码")}
            }
        };present(UINavigationController(rootViewController:scanner),animated:true)
    }
    private func settings(){
        guard let c=coordinator else{return}
        let controller=UIViewController();controller.title="设置与结果";controller.view.backgroundColor = .systemBackground
        let scroll=UIScrollView();scroll.translatesAutoresizingMaskIntoConstraints=false;controller.view.addSubview(scroll)
        let content=UIStackView();content.axis = .vertical;content.spacing=16;content.translatesAutoresizingMaskIntoConstraints=false;scroll.addSubview(content)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo:controller.view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:controller.view.bottomAnchor),scroll.leadingAnchor.constraint(equalTo:controller.view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:controller.view.trailingAnchor),content.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:20),content.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-20),content.leadingAnchor.constraint(equalTo:scroll.frameLayoutGuide.leadingAnchor,constant:24),content.trailingAnchor.constraint(equalTo:scroll.frameLayoutGuide.trailingAnchor,constant:-24)])
        func add(_ title:String,_ action:@escaping @MainActor ()->Void){let b=UIButton(type:.system);b.configuration = .bordered();b.setTitle(title,for:.normal);b.addAction(UIAction{_ in action()},for:.touchUpInside);content.addArrangedSubview(b)}
        add("恢复配对（仅获取恢复配置）"){[weak self] in self?.navigationController?.popViewController(animated:true);self?.scan(recoveryMode:true)}
        add("重新读取并核对历史"){[weak self] in self?.navigationController?.popViewController(animated:true);c.run(historical:true)}
        add("输入接收端当前 IP 和端口"){[weak self] in self?.address()}
        add("清除本应用导入并重建 / 更换来源"){[weak self] in self?.navigationController?.popViewController(animated:true);self?.prepareRebuild()}
        add("清理后按原范围重建"){[weak self] in self?.navigationController?.popViewController(animated:true);self?.adoptRebuild()}
        add("忘记设备，保留导入记录"){[weak self] in self?.navigationController?.popViewController(animated:true);self?.forget()}
        add("打开应用系统设置"){UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!)}
        let text=UILabel();text.numberOfLines=0;text.font = .preferredFont(forTextStyle:.body)
        let details=c.details.isEmpty ? ((try? c.store.get([String].self,"meta","resultDetails")) ?? []):c.details
        text.text="只读取睡眠、运动及已有统计；没有 Apple Health 写权限。\n缓存：\(c.store.cacheBytes) 字节。\n历史删除仅按实际收到的事件处理，可能存在遗漏。不可读记录保留，并暂停其待发送修订。\n源时区未知时 Android 14+ 可能采用接收设备系统时区，历史日期归属需核对。\n活动能量不代表总能量；三星热量可能为空。暂停无法完整表达时不补造暂停。\n\n"+details.joined(separator:"\n")
        content.addArrangedSubview(text);navigationController?.pushViewController(controller,animated:true)
    }
    private func address(){
        let alert=UIAlertController(title:"手动地址",message:"请输入三星接收页当前地址，仍使用相同 TLS 证书校验。",preferredStyle:.alert)
        alert.addTextField{$0.placeholder="192.168.1.100";$0.keyboardType = .decimalPad}
        alert.addTextField{$0.placeholder="端口";$0.keyboardType = .numberPad}
        alert.addAction(UIAlertAction(title:"保存",style:.default){[weak self] _ in
            guard let host=alert.textFields?[0].text,host.split(separator:".").count==4,let port=UInt16(alert.textFields?[1].text ?? ""),port>0 else{return}
            self?.coordinator?.manualAddress=(host,port)
        });alert.addAction(UIAlertAction(title:"取消",style:.cancel));navigationController?.topViewController?.present(alert,animated:true)
    }
    private func forget(){
        showConfirm("忘记设备","iPhone 单端忘记无法撤销离线三星端 token；请同时在三星接收端解绑。健康记录与账本保留。"){
            PairingVault.remove("pairing");self.coordinator?.lan.close();self.refresh()
        }
    }
    private func prepareRebuild(newSource:(String,String)?=nil,confirmedHistory:String?=nil){
        guard let c=coordinator,!c.busy else{return}
        Task{do{
            var dataset=try c.store.dataset
            if dataset.historyStart==nil,let data=try c.store.get(Data.self,"meta","receiverRecovery"),let info=try JSONSerialization.jsonObject(with:data) as? [String:Any],let id=info["datasetId"] as? String,let history=info["historyStart"] as? String,let sources=info["sources"]{
                dataset=Dataset(datasetId:id,historyStart:history,sources:try WireCodec.decode(Sources.self,JSONSerialization.data(withJSONObject:sources)))
                try c.store.put("meta","dataset",dataset)
            }
            if dataset.historyStart==nil {
                guard let confirmedHistory else{self.chooseRecoveryStart(newSource:newSource);return}
                if let data=try c.store.get(Data.self,"meta","receiverRecovery"),let info=try JSONSerialization.jsonObject(with:data) as? [String:Any],let old=info["datasetId"] as? String {dataset.datasetId=old}
                dataset.historyStart=confirmedHistory
                try c.store.put("meta","dataset",dataset);try c.store.put("meta","recovery",true)
            }
            let history=dataset.historyStart!
            var sources=dataset.sources;if let newSource{if newSource.0=="sleep"{sources.sleep=newSource.1}else{sources.workout=newSource.1}}
            let lower=try WireTime.milliseconds(history)
            let sleeps=try await c.reader.sources(kind:"sleep",lowerMs:lower-48*60*60*1000)
            let workouts=try await c.reader.sources(kind:"workout",lowerMs:lower)
            let count=sleeps.filter{$0.bundleIdentifier==sources.sleep}.reduce(0){$0+$1.count}+workouts.filter{$0.bundleIdentifier==sources.workout}.reduce(0){$0+$1.count}
            let previous=try c.store.get(RebuildPlan.self,"meta","plan")
            let plan:RebuildPlan
            if let previous,previous.oldDatasetId==dataset.datasetId,previous.historyStart==history,previous.sources==sources {plan=previous}
            else{plan=RebuildPlan(planId:newID(),oldDatasetId:dataset.datasetId,newDatasetId:newID(),historyStart:history,sources:sources)}
            self.showConfirm("准备原范围重建","起点：\(history)\n当前来源可读 \(count) 条。已知不可读 \(try c.store.list(String.self,"unavailable").count) 条。空结果也可能是读取权限不可见；清理后这些记录可能无法补回。此步骤只保存计划，仍须在三星端确认清理。"){
                Task{do{
                    guard let pair=try PairingVault.read(Pairing.self,key:"pairing")else{throw RelayError.authentication}
                    try c.store.put("meta","plan",plan)
                    try await c.lan.connect(pair,manual:c.manualAddress);_ = try await c.lan.hello(pair,dataset:dataset)
                    let result=try await c.lan.request(type:"prepareRebuild",fields:["rebuildPlan":try JSONSerialization.jsonObject(with:WireCodec.encode(plan))])
                    try c.store.put("meta","receiverRecovery",JSONSerialization.data(withJSONObject:result));c.lan.close();c.update("计划已保存，请在三星手机确认清理")
                }catch{self.show("计划尚未完成",(error as? RelayError)?.rawValue ?? "连接失败；可重试")}}
            }
        }catch{self.show("不能开始清理",(error as? RelayError)?.rawValue ?? "源数据读取失败")}}
    }
    private func chooseRecoveryStart(newSource:(String,String)?) {
        let controller=UIViewController();controller.title="确认恢复范围";controller.view.backgroundColor = .systemBackground
        let content=UIStackView();content.axis = .vertical;content.spacing=24;content.translatesAutoresizingMaskIntoConstraints=false;controller.view.addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo:controller.view.safeAreaLayoutGuide.topAnchor,constant:24),content.leadingAnchor.constraint(equalTo:controller.view.leadingAnchor,constant:24),content.trailingAnchor.constraint(equalTo:controller.view.trailingAnchor,constant:-24)])
        let explanation=UILabel();explanation.numberOfLines=0;explanation.text="两端没有可信的原历史起点。请明确选择重建起点，并在来源页面核对来源。不会默认重置为最近 30 天。此选择仅用于本次恢复。";content.addArrangedSubview(explanation)
        let picker=UIDatePicker();picker.datePickerMode = .dateAndTime;picker.preferredDatePickerStyle = .wheels;picker.maximumDate=Date();content.addArrangedSubview(picker)
        let confirm=UIButton(type:.system);confirm.configuration = .filled();confirm.setTitle("确认这个恢复起点",for:.normal)
        confirm.addAction(UIAction{[weak self] _ in
            let history=WireTime.string(Int64((picker.date.timeIntervalSince1970*1000).rounded()))
            self?.navigationController?.popViewController(animated:true);self?.prepareRebuild(newSource:newSource,confirmedHistory:history)
        },for:.touchUpInside);content.addArrangedSubview(confirm)
        navigationController?.pushViewController(controller,animated:true)
    }
    private func adoptRebuild(){
        guard let c=coordinator,!c.busy else{return}
        do{
            guard let data=try c.store.get(Data.self,"meta","receiverRecovery"),let info=try JSONSerialization.jsonObject(with:data) as? [String:Any],info["rebuildState"] as? String=="cleared",let raw=info["rebuildPlan"]else{show("请先读取清理凭据","三星清理完成后，在接收页显示新的二维码，并在 iPhone 设置中选择“恢复配对”获取同一计划的清理状态。然后再次选择按原范围重建。");return}
            let plan=try WireCodec.decode(RebuildPlan.self,JSONSerialization.data(withJSONObject:raw))
            showConfirm("按原范围重建","保留原起点 \(plan.historyStart)。仅重导当前可读来源。完成切换后重新扫码配对，再点击同步。"){
                do{guard !c.busy else{return};if try c.store.adoptRebuild(plan){PairingVault.remove("pairing");c.update("已切换重建数据集，请重新配对")}else{c.update("已采用此重建计划，保留当前同步进度")} }catch{self.show("恢复失败","配置不一致，已停止")}
            }
        }catch{show("恢复失败","无法读取清理凭据")}
    }
    private func show(_ title:String,_ message:String){let a=UIAlertController(title:title,message:message,preferredStyle:.alert);a.addAction(UIAlertAction(title:"好",style:.default));(navigationController?.topViewController ?? self).present(a,animated:true)}
    private func showConfirm(_ title:String,_ message:String,_ action:@escaping @MainActor ()->Void){let a=UIAlertController(title:title,message:message,preferredStyle:.alert);a.addAction(UIAlertAction(title:"继续",style:.default){_ in action()});a.addAction(UIAlertAction(title:"取消",style:.cancel));present(a,animated:true)}
}

@MainActor final class ScannerViewController:UIViewController,AVCaptureMetadataOutputObjectsDelegate {
    var scanned:((String)->Void)?
    private let capture=AVCaptureSession();private var preview:AVCaptureVideoPreviewLayer?;private var delivered=false
    override func viewDidLoad(){super.viewDidLoad();title="扫描三星配对码";view.backgroundColor = .black
        navigationItem.leftBarButtonItem=UIBarButtonItem(systemItem:.cancel,primaryAction:UIAction{[weak self] _ in self?.dismiss(animated:true)})
        Task{
            guard await AVCaptureDevice.requestAccess(for:.video)else{let a=UIAlertController(title:"相机未授权",message:"请在系统设置中允许相机；不提供弱口令或明文配对。",preferredStyle:.alert);a.addAction(UIAlertAction(title:"好",style:.default){[weak self] _ in self?.dismiss(animated:true)});present(a,animated:true);return}
            do{guard let device=AVCaptureDevice.default(for:.video)else{return};let input=try AVCaptureDeviceInput(device:device);capture.addInput(input)
                let output=AVCaptureMetadataOutput();capture.addOutput(output);output.setMetadataObjectsDelegate(self,queue:.main);output.metadataObjectTypes=[.qr]
                let preview=AVCaptureVideoPreviewLayer(session:capture);preview.videoGravity = .resizeAspectFill;view.layer.insertSublayer(preview,at:0);self.preview=preview;preview.frame=view.bounds
                let session=capture;Task.detached{session.startRunning()}
            }catch{dismiss(animated:true)}
        }
    }
    override func viewDidLayoutSubviews(){super.viewDidLayoutSubviews();preview?.frame=view.bounds}
    override func viewWillDisappear(_ animated:Bool){super.viewWillDisappear(animated);let session=capture;Task.detached{session.stopRunning()}}
    nonisolated func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput metadataObjects:[AVMetadataObject],from connection:AVCaptureConnection){
        guard let value=(metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else{return}
        Task{@MainActor in guard !delivered else{return};delivered=true;scanned?(value)}
    }
}
