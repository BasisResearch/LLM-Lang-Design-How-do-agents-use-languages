import Server.Core
import Server.Run

-- No networking in Lean due to environment limitations; binary acts as inetd-style filter.
-- run.sh will provide TCP socket handling.
