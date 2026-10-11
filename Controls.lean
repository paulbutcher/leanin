import Std

import LeanIn.Test.Control
import LeanIn.Test.Send
import LeanIn.Test.ExecutorNarrowing

/-- Entry point for the bridge-axiom controls. Body lives in `LeanIn.Test.Control`. -/
def main (args : List String) : IO UInt32 := LeanIn.Test.main args
