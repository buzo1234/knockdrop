import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var input = model.input
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $model.name, prompt: Text(UIDevice.current.name))
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Your name")
                } footer: {
                    Text("What people nearby see when you share.")
                }

                if input.motionAvailable {
                    Section {
                        Toggle("Feel knocks on the table", isOn: $input.feelKnocks)
                        if input.feelKnocks {
                            VStack(alignment: .leading) {
                                Text("Sensitivity")
                                Slider(value: Binding(get: { 8 - input.threshold }, set: { input.threshold = 8 - $0 }),
                                       in: 2...6) {
                                    Text("Sensitivity")
                                } minimumValueLabel: {
                                    Image(systemName: "tortoise")
                                } maximumValueLabel: {
                                    Image(systemName: "hare")
                                }
                            }
                            HStack {
                                Text("Knock on the table to test")
                                Spacer()
                                Image(systemName: "waveform.path")
                                    .foregroundStyle(.tint)
                                    .symbolEffect(.bounce, value: input.feltCount)
                                Text("\(input.feltCount)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("While KnockDrop is open, your phone feels knocks on the table it's lying on. When someone at the table knocks a rhythm to share, it lands on your phone without you tapping anything. Turn this off if you don't want that.")
                    }
                }

                Section {
                    Text("Someone shares by knocking a secret rhythm on their Mac or tapping it on their phone. To receive, tap the same rhythm here. Only the shape of the rhythm counts, not the speed.")
                    Text("Clipboard shares land on your clipboard. Files land in Files › On My iPhone › KnockDrop.")
                    Text("Nothing is encrypted and a rhythm is a weak password. Fine for photos and notes on home or office Wi-Fi, not for secrets.")
                        .foregroundStyle(.secondary)
                    Link("KnockDrop for Mac", destination: URL(string: "https://github.com/buzo1234/knockdrop")!)
                } header: {
                    Text("How it works")
                }
                .font(.callout)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
