// Fixed implementations for server issues

There are several critical bugs in the code:
1. The server is crashing with a segmentation fault
2. Cookie extraction has issues 
3. Header parsing problems
4. Buffer overflow potential

The main issue seems to be in the process_request function where I'm manipulating string pointers.