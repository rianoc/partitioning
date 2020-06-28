/ use timespan with kdb+tick v2.5 or higher. Prior versions use time type
quote:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$();bsize:`int$();asize:`int$())
trade:([]time:`timestamp$();sym:`symbol$();price:`float$();size:`int$())
