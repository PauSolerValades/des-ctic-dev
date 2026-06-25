# The simulation

There is a lot to be said about this program, and I don't want to do it rn to be honest.

## TODO: 
[ ] Add the `inter_session_length`, `inter_post_creation` and `session_lenght` into the JSON. That means building a custom parser that can accept a normal distribution (then everyone has the same one) or a file to sample from given it's in the proper format.
[ ] In the traces file output a `usersample` with which parameters did the user follow, as well as one with the base metrics as it's randomly sampled and changes per distribution.
[ ] Memory Pool for the UserTimelines. It is definetly not hurting performance. Probably would make sense to wait for 0.17.0 to do that.
