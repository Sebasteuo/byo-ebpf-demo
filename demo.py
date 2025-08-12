#!/usr/bin/env python3
import logging, random, time, sys, os, signal

LOGFILE = "/var/log/demo.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[
        logging.FileHandler(LOGFILE),
        logging.StreamHandler(sys.stdout)
    ])

cards = ["4111111111111111", "5555555555554444", "378282246310005"]
ssn   = ["123-45-6789", "987-65-4321"]

def handler(sig, frame):
    logging.info("Shutting down")
    sys.exit(0)
signal.signal(signal.SIGINT, handler)

while True:
    logging.info("Purchase card=%s ssn=%s total=$%d",
                 random.choice(cards),
                 random.choice(ssn),
                 random.randint(10, 500))
    time.sleep(0.2)
