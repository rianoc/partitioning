#!/bin/bash

q tick.q sym .             -p 5010 &
q tick/r.q :5010 :5012 HDB -p 5011 &
q HDB                      -p 5012 &
q ../feed.q :5010          -p 5013 &
