#!/bin/bash
set -e
# Defaults:
# CriticalPowerAction=HybridSleep
# PercentageAction=2
# PercentageLow=20
sed -i /etc/UPower/UPower.conf \
	-e 's/^CriticalPowerAction=.*/CriticalPowerAction=PowerOff/' \
	-e 's/^PercentageAction=.*/PercentageAction=3/' \
	-e 's/^PercentageLow=.*/PercentageLow=10/'
