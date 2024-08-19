CREATE DATABASE product;
USE product;

CREATE TABLE product (
	id VARCHAR(255) PRIMARY KEY,
	name VARCHAR(255),
	category VARCHAR(255)
);

CREATE DATABASE customer;
USE customer;

CREATE TABLE customer (
	id VARCHAR(255) PRIMARY KEY,
	name VARCHAR(255),
	gender VARCHAR(255)
);

