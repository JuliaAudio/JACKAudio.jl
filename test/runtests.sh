 #!/bin/sh

 # run the jack server in the background
jackd -r -p4 -ddummy -r48000 -p2048 -w100000 &
sleep 5
julia -e 'Pkg.clone(pwd()); Pkg.build("JACKAudio"); Pkg.test("JACKAudio"; coverage=true)'
killall jackd