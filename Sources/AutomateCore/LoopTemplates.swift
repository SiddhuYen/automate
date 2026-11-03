import Foundation

/// The blank loop file behind *New Loop*. Automate ships no starter loops: you make your own.
public enum LoopTemplates {
    public struct Template: Sendable {
        public let fileName: String
        public let title: String
        public let contents: String
    }

    public static let blank = Template(fileName: "new-loop", title: "Blank loop", contents: """
    ---
    name: New loop
    enabled: false
    schedule: daily 09:00        # every 30m | hourly | weekdays 18:30 | mon,wed 07:15
    triggers: []                 # launch, wake, unlock
    autonomy: ask                # auto | ask | split
    permission: auto             # used when the loop is allowed to act
    model: opus
    effort: high
    notify: changes              # always | changes | never
    catch_up: true               # run after waking if the Mac slept through the time
    timeout: 30m
    # cwd: ~/code/my-repo        # leave out to work in the loop's own notes folder
    ---
    Describe the job here, step by step.
    Say which parts are safe to do automatically and which need approval.
    """)
}
