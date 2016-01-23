"""
This RingBuffer type is a non-blocking fixed-size buffer. In overflow conditions
(writing to an already-full buffer), the old data is overwritten by the new.
"""

# TODO: rework read/write methods to use subarrays rather than normal indexing
# which creates a copy

type RingBuffer{T}
    buf::Vector{T}
    readidx::UInt
    navailable::UInt
    
    RingBuffer(size) = new(Array(T, size), 1, 0)
end

RingBuffer(T, size) = RingBuffer{T}(nextpow2(size))

read_space(rb::RingBuffer) = rb.navailable

write_space(rb::RingBuffer) = length(rb.buf) - read_space(rb)

"""Read the ringbuffer contents into the given vector `v`. Returns the number
of elements actually read"""
function Base.read!{T}(rb::RingBuffer{T}, v::Vector{T})
    buflen = length(rb.buf)
    total = min(length(v), read_space(rb))
    if rb.readidx + total - 1 <= buflen
        v[1:total] = rb.buf[rb.readidx:(rb.readidx+total-1)]
    else
        partial = buflen - rb.readidx + 1
        v[1:partial] = rb.buf[rb.readidx:buflen]
        v[(partial+1):total] = rb.buf[1:(total-partial)]
    end
    
    rb.readidx = wrapidx(rb, rb.readidx + total)
    rb.navailable -= total
    # println("new readidx: $(rb.readidx)")
    # println("new navailable: $(rb.navailable)")
    
    total
end

"""Read at most `n` bytes from the ring buffer, returning the results as a new
Vector{T}"""
function Base.read{T}(rb::RingBuffer{T}, n)
    size = min(n, read_space(rb))
    v = Array(T, size)
    read!(rb, v)
    
    v
end

"""Write the given vector `v` to the buffer `rb`. If there is not enough space
in the buffer to hold the contents, old data is overwritten by new"""
function Base.write{T}(rb::RingBuffer{T}, v::Vector{T})
    buflen = length(rb.buf)
    vlen = length(v)
    if vlen >= buflen
        # we're totally overwriting the contents of the buffer. Just take
        # the end of the given vector and fill our buffer with it
        rb.readidx = 1
        rb.navailable = buflen
        rb.buf[1:buflen] = v[(vlen-buflen+1):vlen]
    else
        # we're keeping some data
        start = Int(wrapidx(rb, rb.readidx + read_space(rb)))
        if start + vlen - 1 <= buflen
            rb.buf[start:(start+vlen-1)] = v[:]
        else
            rb.buf[start:buflen] = v[1:(buflen-start+1)]
            rb.buf[1:(vlen-buflen+start-1)] = v[(buflen-start+2):vlen]
        end
        
        if vlen > write_space(rb)
            # we overwrote some data, so bump the read pointer
            rb.readidx = wrapidx(rb, rb.readidx + (vlen - write_space(rb)))
            rb.navailable = buflen
        else
            rb.navailable += vlen
        end
    end
    # println("new readidx: $(rb.readidx)")
    # println("new navailable: $(rb.navailable)")
        
    nothing
end

# this works because we know the buffer size is a power of two
wrapidx{T}(rb::RingBuffer{T}, val::Unsigned) = (val - 1) & (length(rb.buf) - 1) + 1